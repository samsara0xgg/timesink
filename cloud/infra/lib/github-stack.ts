import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';

/**
 * What GitHub Actions may be in this account: one role that only a workflow
 * run on this repository's main branch can assume, and that can do no more
 * than the CDK bootstrap roles it hands off to. GitHub proves itself with a
 * short-lived OIDC token per run, so no access key exists anywhere.
 *
 * Deployed by hand, never by CI: a pipeline must not be able to widen its
 * own trust. `.github/workflows/deploy.yml` deploys the TimeSink stack only.
 */
export class GithubStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: cdk.StackProps & { repo: string }) {
    super(scope, id, props);

    const github = new iam.OidcProviderNative(this, 'Github', {
      url: 'https://token.actions.githubusercontent.com',
      clientIds: ['sts.amazonaws.com'],
    });

    const role = new iam.Role(this, 'Deploy', {
      roleName: 'TimeSinkGithubDeploy',
      assumedBy: new iam.WebIdentityPrincipal(github.oidcProviderArn, {
        StringEquals: { 'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com' },
        StringLike: { 'token.actions.githubusercontent.com:sub': `repo:${props.repo}:ref:refs/heads/main` },
      }),
      maxSessionDuration: cdk.Duration.hours(1),
    });
    // `cdk deploy` itself only assumes the bootstrap roles (deploy, file
    // publishing, lookup); CloudFormation does the rest with the bootstrap
    // execution role.
    role.addToPolicy(new iam.PolicyStatement({
      actions: ['sts:AssumeRole'],
      resources: [`arn:aws:iam::${this.account}:role/cdk-hnb659fds-*`],
    }));

    new cdk.CfnOutput(this, 'RoleArn', { value: role.roleArn });
  }
}
