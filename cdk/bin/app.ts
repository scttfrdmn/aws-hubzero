#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { HubzeroStack } from "../lib/hubzero-stack";

const app = new cdk.App();
const env = app.node.tryGetContext("environment") || "test";

new HubzeroStack(app, `hubzero-${env}`, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || "us-east-1",
  },
  environment: env,
});
