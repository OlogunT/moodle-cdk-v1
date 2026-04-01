#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { MoodleCdkStack } from '../lib/moodle-cdk-stack';
import { TrainingMoodleCdkStack } from '../lib/training-moodle-cdk-stack';

const app = new cdk.App();

// Learning Moodle Stack (existing - elearning.tsin.ca)
new MoodleCdkStack(app, 'MoodleCdkStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: 'ca-central-1',
  },
  description: 'Moodle 5 deployment with MariaDB RDS, EFS, and Auto Scaling',
  tags: {
    Project: 'Moodle-CDK',
    Environment: 'Production',
    Owner: 'Touchstone Institute',
    Instance: 'Learning'
  }
});

// Training Moodle Stack (new - training.tsin.ca)
// Shares VPC with Learning stack but has separate RDS, EFS, ALB, ASG
new TrainingMoodleCdkStack(app, 'TrainingMoodleCdkStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: 'ca-central-1',
  },
  description: 'Training Moodle deployment with MariaDB RDS, EFS, and Auto Scaling (shares VPC with Learning)',
  tags: {
    Project: 'Training-Moodle-CDK',
    Environment: 'Production',
    Owner: 'Touchstone Institute',
    Instance: 'Training'
  }
});
