import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpUserPoolAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';

/**
 * Everything the Mac app talks to. See
 * docs/superpowers/specs/2026-09-22-timesink-cloud-design.md §3.
 *
 * The user pool and the table are RETAINed: a `cdk destroy` must never take
 * users' accounts or their history with it.
 */
export class TimeSinkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const userPool = new cognito.UserPool(this, 'Users', {
      selfSignUpEnabled: true,
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
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    table.addGlobalSecondaryIndex({
      indexName: 'bySeq',
      partitionKey: { name: 'userId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'seq', type: dynamodb.AttributeType.STRING },
    });

    const api = new lambda.Function(this, 'Api', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '..', '..', 'api'), {
        exclude: ['.venv', '.mise.toml', 'pyproject.toml', 'uv.lock', 'test_*.py', '__pycache__', '.pytest_cache'],
      }),
      environment: { TABLE_NAME: table.tableName, USER_POOL_ID: userPool.userPoolId },
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
    });
    table.grantReadWriteData(api);
    userPool.grant(api, 'cognito-idp:AdminDeleteUser');

    const httpApi = new apigw.HttpApi(this, 'Http', {
      defaultAuthorizer: new HttpUserPoolAuthorizer('Jwt', userPool, { userPoolClients: [client] }),
    });
    const integration = new HttpLambdaIntegration('Lambda', api);
    httpApi.addRoutes({ path: '/spans', methods: [apigw.HttpMethod.POST, apigw.HttpMethod.GET], integration });
    httpApi.addRoutes({ path: '/account', methods: [apigw.HttpMethod.DELETE], integration });

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

    // The three values CloudConfig.swift carries.
    new cdk.CfnOutput(this, 'AuthDomain', { value: domain.baseUrl() });
    new cdk.CfnOutput(this, 'ClientId', { value: client.userPoolClientId });
    new cdk.CfnOutput(this, 'ApiUrl', { value: httpApi.apiEndpoint });
  }
}
