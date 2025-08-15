#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { MoodleCdkStack } from '../lib/moodle-cdk-stack';

const app = new cdk.App();

new MoodleCdkStack(app, 'MoodleCdkStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: 'ca-central-1',
  },
  description: 'Moodle 5 deployment with MariaDB RDS, EFS, and Auto Scaling',
  tags: {
    Project: 'Moodle-CDK',
    Environment: 'Development',
    Owner: 'Touchstone Institute'
  }
});
