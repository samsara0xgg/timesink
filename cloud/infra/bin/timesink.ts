#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { GithubStack } from '../lib/github-stack';
import { TimeSinkStack } from '../lib/timesink-stack';

const app = new cdk.App();
const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'us-west-2' };

new TimeSinkStack(app, 'TimeSink', { env });
// Hand-deployed; see the class comment. GitHub's OIDC subject names the
// owner and repository with their immutable ids (`owner@id/repo@id`), so
// a renamed or re-registered name can never inherit this trust. The ids:
// `gh api users/samsara0xgg --jq .id`, `gh api repos/samsara0xgg/timesink --jq .id`.
new GithubStack(app, 'TimeSinkGithub', { env, repo: 'samsara0xgg@272073393/timesink@1382455718' });
