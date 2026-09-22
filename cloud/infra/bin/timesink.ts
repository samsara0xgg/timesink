#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { TimeSinkStack } from '../lib/timesink-stack';

const app = new cdk.App();
new TimeSinkStack(app, 'TimeSink', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'us-west-2' },
});
