import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import * as budgets from 'aws-cdk-lib/aws-budgets';
import { HttpUserPoolAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cwActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as subs from 'aws-cdk-lib/aws-sns-subscriptions';
import { Construct } from 'constructs';

/**
 * Everything the Mac app talks to. See
 * docs/superpowers/specs/2026-09-22-timesink-cloud-design.md §3.
 *
 * The user pool and the table are RETAINed: a `cdk destroy` must never take
 * users' accounts or their history with it.
 *
 * Two opt-ins, both off by default because each needs something in the
 * account first. Pass them as CDK context (`-c key=value`, or in cdk.json);
 * deploy.yml passes them from repository variables (SES_FROM_EMAIL, ...,
 * API_RESERVED_CONCURRENCY), and an unset or empty one means off.
 *
 * - `sesFromEmail` (and optionally `sesFromName`, `sesReplyTo`, `sesRegion`,
 *   `sesVerifiedDomain`): Cognito sends sign-up and password-reset mail
 *   through SES instead of its built-in sender, which stops at 50 messages a
 *   day. First verify the address (or its domain) in SES, in `sesRegion`
 *   (default: this stack's region), and move SES out of the sandbox, which
 *   otherwise only delivers to verified recipients.
 * - `apiReservedConcurrency` (e.g. 10): caps how many copies of the API
 *   Lambda run at once. AWS refuses it unless the account keeps 10
 *   unreserved, so first check that `aws lambda get-account-settings` shows
 *   a ConcurrentExecutions limit of at least the value plus 10 (new accounts
 *   can start at 10).
 */
export class TimeSinkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const ctx = (key: string): string | undefined => {
      const v = this.node.tryGetContext(key);
      return v === undefined || v === null || `${v}`.trim() === '' ? undefined : `${v}`.trim();
    };

    const sesFromEmail = ctx('sesFromEmail');
    const userPool = new cognito.UserPool(this, 'Users', {
      selfSignUpEnabled: true,
      email: sesFromEmail
        ? cognito.UserPoolEmail.withSES({
            fromEmail: sesFromEmail,
            fromName: ctx('sesFromName'),
            replyTo: ctx('sesReplyTo'),
            sesRegion: ctx('sesRegion') ?? this.region,
            sesVerifiedDomain: ctx('sesVerifiedDomain'),
          })
        : undefined,
      signInAliases: { email: true },
      autoVerify: { email: true },
      standardAttributes: { email: { required: true, mutable: false } },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // A public client: the app proves itself with PKCE, not a secret.
    const client = userPool.addClient('Mac', {
      generateSecret: false,
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL],
        callbackUrls: ['timesink://auth'],
        logoutUrls: ['timesink://signout'],
      },
      refreshTokenValidity: cdk.Duration.days(180),
      preventUserExistenceErrors: true,
    });

    const domain = userPool.addDomain('Domain', {
      cognitoDomain: { domainPrefix: `timesink-${this.account}` },
    });

    const table = new dynamodb.Table(this, 'Spans', {
      partitionKey: { name: 'userId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'sk', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      // The API's per-user rate and daily counters and the deleted-account
      // marker expire on their own; span items never carry the attribute.
      timeToLiveAttribute: 'expiresAt',
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    table.addGlobalSecondaryIndex({
      indexName: 'bySeq',
      partitionKey: { name: 'userId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'seq', type: dynamodb.AttributeType.STRING },
    });

    const reserved = ctx('apiReservedConcurrency');
    if (reserved !== undefined && !/^[1-9][0-9]*$/.test(reserved)) {
      throw new Error(`apiReservedConcurrency must be a positive integer, got ${reserved}`);
    }
    const api = new lambda.Function(this, 'Api', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '..', '..', 'api'), {
        exclude: ['.venv', '.mise.toml', 'pyproject.toml', 'uv.lock', 'test_*.py', '__pycache__', '.pytest_cache'],
      }),
      environment: { TABLE_NAME: table.tableName, USER_POOL_ID: userPool.userPoolId },
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      reservedConcurrentExecutions: reserved === undefined ? undefined : Number(reserved),
      // Errors can echo synced titles and URLs, so logs do not outlive a month.
      logGroup: new logs.LogGroup(this, 'ApiLogs', {
        retention: logs.RetentionDays.ONE_MONTH,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      }),
    });
    table.grantReadWriteData(api);
    // DELETE /account signs the user out everywhere and disables them; the
    // delete job it starts removes the user once the table is empty.
    userPool.grant(api, 'cognito-idp:AdminUserGlobalSignOut', 'cognito-idp:AdminDisableUser', 'cognito-idp:AdminDeleteUser');
    // The delete job is the function invoking itself asynchronously. A
    // policy of its own: in the role's default policy the function's ARN
    // would make the function depend on itself.
    new iam.Policy(this, 'ApiSelfInvoke', {
      roles: [api.role!],
      statements: [new iam.PolicyStatement({ actions: ['lambda:InvokeFunction'], resources: [api.functionArn] })],
    });

    const httpApi = new apigw.HttpApi(this, 'Http', {
      defaultAuthorizer: new HttpUserPoolAuthorizer('Jwt', userPool, { userPoolClients: [client] }),
    });
    const integration = new HttpLambdaIntegration('Lambda', api);
    httpApi.addRoutes({ path: '/spans', methods: [apigw.HttpMethod.POST, apigw.HttpMethod.GET], integration });
    httpApi.addRoutes({ path: '/account', methods: [apigw.HttpMethod.DELETE], integration });

    // Sign-up is open, so the stage caps the whole API: far above what a
    // few Macs syncing need, far below a bill. Over it, clients get 429 and
    // back off. Each user is also held to a request rate and a daily row
    // count inside the Lambda (cloud/api/handler.py), so no one account can
    // run up the bill; this cap is shared, and only per-client throttling in
    // front of the API (WAF, which an HTTP API cannot take) would stop one
    // account crowding out the rest. HttpApi takes no throttle for its
    // default stage, hence the escape hatch.
    const stage = httpApi.defaultStage!.node.defaultChild as apigw.CfnStage;
    stage.defaultRouteSettings = { throttlingRateLimit: 20, throttlingBurstLimit: 40 };

    // Where the app downloads from: disk images and the Sparkle appcast,
    // uploaded by scripts/release.sh. Private bucket, served through
    // CloudFront only. The appcast is uploaded with a short max-age, so
    // no invalidation is needed after a release.
    const releases = new s3.Bucket(this, 'Releases', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    const downloads = new cloudfront.Distribution(this, 'Downloads', {
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(releases),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
      },
    });
    new cdk.CfnOutput(this, 'ReleasesBucket', { value: releases.bucketName });
    new cdk.CfnOutput(this, 'DownloadsUrl', { value: `https://${downloads.distributionDomainName}` });

    // A monthly cost alarm for the whole account, emailed at $5 spent and
    // when $10 is forecast. Credits are excluded: the promotional credit
    // pays the bill for now, and an alarm on the net would never fire.
    // The address stays out of the repository: deploy.yml passes it from
    // the ALERT_EMAIL secret, and a deploy without it keeps the last one.
    const alertEmail = new cdk.CfnParameter(this, 'AlertEmail', { type: 'String', noEcho: true });
    const alert = [{ subscriptionType: 'EMAIL', address: alertEmail.valueAsString }];

    // The same address hears when the API breaks: any Lambda error or 5xx
    // in five minutes. Bad requests are 400s and never count.
    const alarms = new sns.Topic(this, 'Alarms');
    alarms.addSubscription(new subs.EmailSubscription(alertEmail.valueAsString));
    const failures: Record<string, cloudwatch.IMetric> = {
      ApiErrors: api.metricErrors({ period: cdk.Duration.minutes(5), statistic: 'Sum' }),
      Api5xx: httpApi.metricServerError({ period: cdk.Duration.minutes(5), statistic: 'Sum' }),
    };
    for (const [id, metric] of Object.entries(failures)) {
      new cloudwatch.Alarm(this, id, {
        metric,
        threshold: 1,
        evaluationPeriods: 1,
        comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      }).addAlarmAction(new cwActions.SnsAction(alarms));
    }
    new budgets.CfnBudget(this, 'MonthlyCost', {
      budget: {
        budgetType: 'COST',
        timeUnit: 'MONTHLY',
        budgetLimit: { amount: 10, unit: 'USD' },
        costTypes: { includeCredit: false, includeRefund: false },
      },
      notificationsWithSubscribers: [
        {
          notification: { notificationType: 'ACTUAL', comparisonOperator: 'GREATER_THAN', threshold: 50, thresholdType: 'PERCENTAGE' },
          subscribers: alert,
        },
        {
          notification: { notificationType: 'FORECASTED', comparisonOperator: 'GREATER_THAN', threshold: 100, thresholdType: 'PERCENTAGE' },
          subscribers: alert,
        },
      ],
    });

    // The three values CloudConfig.swift carries.
    new cdk.CfnOutput(this, 'AuthDomain', { value: domain.baseUrl() });
    new cdk.CfnOutput(this, 'ClientId', { value: client.userPoolClientId });
    new cdk.CfnOutput(this, 'ApiUrl', { value: httpApi.apiEndpoint });
  }
}
