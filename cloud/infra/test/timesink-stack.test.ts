// The promises the stacks' comments make, held as tests: user data
// survives a destroy, nothing is reachable without a token, the API is
// capped and watched, and only main may deploy. `npm test`; no AWS needed.
import { test } from 'node:test';
import * as cdk from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { GithubStack } from '../lib/github-stack';
import { TimeSinkStack } from '../lib/timesink-stack';

const timesink = Template.fromStack(new TimeSinkStack(new cdk.App(), 'TimeSink'));
const github = Template.fromStack(new GithubStack(new cdk.App(), 'TimeSinkGithub', { repo: 'owner@1/repo@2' }));

test('user accounts and history survive a destroy', () => {
  timesink.hasResource('AWS::Cognito::UserPool', { DeletionPolicy: 'Retain', UpdateReplacePolicy: 'Retain' });
  timesink.hasResource('AWS::DynamoDB::Table', {
    DeletionPolicy: 'Retain',
    Properties: { PointInTimeRecoverySpecification: { PointInTimeRecoveryEnabled: true } },
  });
});

test('every route needs a Cognito token', () => {
  const routes = timesink.findResources('AWS::ApiGatewayV2::Route');
  if (Object.keys(routes).length !== 3) throw new Error(`expected 3 routes, got ${Object.keys(routes).length}`);
  for (const [id, route] of Object.entries(routes)) {
    if (route.Properties.AuthorizationType !== 'JWT') throw new Error(`${id} is not behind the JWT authorizer`);
  }
});

test('the API is throttled', () => {
  timesink.hasResourceProperties('AWS::ApiGatewayV2::Stage', {
    DefaultRouteSettings: { ThrottlingRateLimit: Match.anyValue(), ThrottlingBurstLimit: Match.anyValue() },
  });
});

test('Lambda logs expire', () => {
  timesink.hasResourceProperties('AWS::Logs::LogGroup', { RetentionInDays: 30 });
});

test('failures reach the alert address', () => {
  timesink.resourceCountIs('AWS::CloudWatch::Alarm', 2);
  timesink.allResourcesProperties('AWS::CloudWatch::Alarm', { AlarmActions: [{ Ref: Match.stringLikeRegexp('Alarms') }] });
  timesink.hasResourceProperties('AWS::SNS::Subscription', { Protocol: 'email', Endpoint: { Ref: 'AlertEmail' } });
});

test('the release bucket is private', () => {
  timesink.hasResourceProperties('AWS::S3::Bucket', {
    PublicAccessBlockConfiguration: {
      BlockPublicAcls: true, BlockPublicPolicy: true, IgnorePublicAcls: true, RestrictPublicBuckets: true,
    },
  });
});

test('only main of the one repository may deploy, and only through the CDK roles', () => {
  github.hasResourceProperties('AWS::IAM::Role', {
    AssumeRolePolicyDocument: {
      Statement: [Match.objectLike({
        Condition: {
          StringEquals: { 'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com' },
          StringLike: { 'token.actions.githubusercontent.com:sub': 'repo:owner@1/repo@2:ref:refs/heads/main' },
        },
      })],
    },
  });
  github.hasResourceProperties('AWS::IAM::Policy', {
    PolicyDocument: {
      Statement: [Match.objectLike({
        Action: 'sts:AssumeRole',
        Resource: { 'Fn::Join': ['', Match.arrayWith([Match.stringLikeRegexp(':role/cdk-hnb659fds-\\*$')])] },
      })],
    },
  });
});
