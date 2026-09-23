#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { GithubStack } from '../lib/github-stack';
import { TimeSinkStack } from '../lib/timesink-stack';

const app = new cdk.App();
const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'us-west-2' };

new TimeSinkStack(app, 'TimeSink', { env });
// Hand-deployed once; see the class comment.
new GithubStack(app, 'TimeSinkGithub', { env, repo: 'samsara0xgg/timesink' });
