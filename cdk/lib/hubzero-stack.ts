import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as rds from "aws-cdk-lib/aws-rds";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as dlm from "aws-cdk-lib/aws-dlm";
import * as iam from "aws-cdk-lib/aws-iam";
import * as sns from "aws-cdk-lib/aws-sns";
import * as snsSubscriptions from "aws-cdk-lib/aws-sns-subscriptions";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as cloudwatchActions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as logs from "aws-cdk-lib/aws-logs";
import { readFileSync } from "fs";
import { join } from "path";
import { Construct } from "constructs";

interface HubzeroStackProps extends cdk.StackProps {
  environment: string;
}

const VALID_ENVIRONMENTS = ["test", "staging", "prod"];

const ENV_CONFIG: Record<string, { instanceType: string; volumeSize: number }> =
  {
    test: { instanceType: "t3.xlarge", volumeSize: 100 },
    staging: { instanceType: "m6i.2xlarge", volumeSize: 500 },
    prod: { instanceType: "m6i.4xlarge", volumeSize: 1000 },
  };

const RDS_CONFIG: Record<
  string,
  { instanceType: string; storage: number; multiAz: boolean }
> = {
  test: { instanceType: "t3.medium", storage: 20, multiAz: false },
  staging: { instanceType: "r6g.xlarge", storage: 100, multiAz: false },
  prod: { instanceType: "r6g.2xlarge", storage: 500, multiAz: true },
};

const MONITORING_CONFIG: Record<
  string,
  {
    logRetention: logs.RetentionDays;
    cpuThreshold: number;
    alarmPeriod: cdk.Duration;
    evalPeriods: number;
  }
> = {
  test: {
    logRetention: logs.RetentionDays.ONE_WEEK,
    cpuThreshold: 80,
    alarmPeriod: cdk.Duration.seconds(300),
    evalPeriods: 2,
  },
  staging: {
    logRetention: logs.RetentionDays.TWO_WEEKS,
    cpuThreshold: 75,
    alarmPeriod: cdk.Duration.seconds(300),
    evalPeriods: 2,
  },
  prod: {
    logRetention: logs.RetentionDays.ONE_MONTH,
    cpuThreshold: 70,
    alarmPeriod: cdk.Duration.seconds(60),
    evalPeriods: 3,
  },
};

export class HubzeroStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: HubzeroStackProps) {
    super(scope, id, props);

    if (!VALID_ENVIRONMENTS.includes(props.environment)) {
      throw new Error(
        `Invalid environment "${props.environment}". Must be one of: ${VALID_ENVIRONMENTS.join(", ")}`
      );
    }

    const config = ENV_CONFIG[props.environment];
    const vpcId = this.node.tryGetContext("vpcId");
    const keyName = this.node.tryGetContext("keyName") || "";
    const allowedCidr: string = this.node.tryGetContext("allowedCidr");
    if (!allowedCidr) {
      throw new Error(
        "allowedCidr is required — set to your IP (e.g. 203.0.113.5/32)"
      );
    }
    if (
      props.environment !== "test" &&
      !allowedCidr.match(/^(\d{1,3}\.){3}\d{1,3}\/3[0-2]$/)
    ) {
      throw new Error(
        "For staging/prod, allowedCidr must be /30 or narrower (e.g. x.x.x.x/32)"
      );
    }
    const domainName = this.node.tryGetContext("domainName") || "";
    const certbotEmail = this.node.tryGetContext("certbotEmail") || "";
    const installPlatform =
      this.node.tryGetContext("installPlatform") || "false";
    const useRds = this.node.tryGetContext("useRds") === "true";
    const enableS3Storage = this.node.tryGetContext("enableS3Storage") !== "false";
    const enableMonitoring = this.node.tryGetContext("enableMonitoring") !== "false";
    const alarmEmail: string = this.node.tryGetContext("alarmEmail") || "";
    const monConfig = MONITORING_CONFIG[props.environment];
    const logGroupPrefix = `/aws/ec2/hubzero-${props.environment}`;

    const vpc = ec2.Vpc.fromLookup(this, "Vpc", { vpcId });

    // --- Security Group (no SSH — use SSM) ---
    const sg = new ec2.SecurityGroup(this, "SG", {
      vpc,
      description: `HubZero ${props.environment}`,
      allowAllOutbound: false,
    });
    for (const port of [80, 443]) {
      sg.addIngressRule(
        ec2.Peer.ipv4(allowedCidr),
        ec2.Port.tcp(port),
        `Port ${port}`
      );
    }
    sg.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(443),
      "HTTPS outbound"
    );
    sg.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(80),
      "HTTP outbound"
    );
    sg.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.udp(53),
      "DNS UDP outbound"
    );
    sg.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(53),
      "DNS TCP outbound"
    );

    const ami = ec2.MachineImage.latestAmazonLinux2023({
      cpuType: ec2.AmazonLinuxCpuType.X86_64,
    });

    // --- RDS (optional) ---
    let dbHost = "localhost";
    let dbSecretArn = "";
    let dbInstance: rds.DatabaseInstance | undefined;

    if (useRds) {
      const rdsConfig = RDS_CONFIG[props.environment];

      const rdsSg = new ec2.SecurityGroup(this, "RdsSG", {
        vpc,
        description: `HubZero RDS ${props.environment}`,
        allowAllOutbound: false,
      });
      rdsSg.addIngressRule(sg, ec2.Port.tcp(3306), "EC2 to RDS");

      // Allow EC2 to reach RDS
      sg.addEgressRule(rdsSg, ec2.Port.tcp(3306), "EC2 to RDS");

      dbInstance = new rds.DatabaseInstance(this, "Database", {
        engine: rds.DatabaseInstanceEngine.mariaDb({
          version: rds.MariaDbEngineVersion.VER_10_11,
        }),
        instanceType: new ec2.InstanceType(`db.${rdsConfig.instanceType}`),
        vpc,
        vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
        publiclyAccessible: false,
        securityGroups: [rdsSg],
        multiAz: rdsConfig.multiAz,
        allocatedStorage: rdsConfig.storage,
        storageType: rds.StorageType.GP3,
        storageEncrypted: true,
        databaseName: "hubzero",
        credentials: rds.Credentials.fromUsername("hubzero", {
          excludeCharacters: "\"@/\\",
        }),
        backupRetention: cdk.Duration.days(
          props.environment === "prod" ? 14 : 7
        ),
        deletionProtection: props.environment === "prod",
        removalPolicy:
          props.environment === "prod"
            ? cdk.RemovalPolicy.SNAPSHOT
            : cdk.RemovalPolicy.DESTROY,
      });

      // Use RDS-managed master password (keeps password out of CloudFormation)
      const cfnDb = dbInstance.node.defaultChild as rds.CfnDBInstance;
      cfnDb.addPropertyOverride("ManageMasterUserPassword", true);
      cfnDb.addDeletionOverride("Properties.MasterUserPassword");

      dbHost = dbInstance.dbInstanceEndpointAddress;
      dbSecretArn = cfnDb.attrMasterUserSecretSecretArn;
    }

    // --- S3 File Storage (optional) ---
    let s3BucketName = "";
    if (enableS3Storage) {
      const storageBucket = new s3.Bucket(this, "StorageBucket", {
        versioned: true,
        encryption: s3.BucketEncryption.KMS_MANAGED,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        lifecycleRules: [
          {
            id: "transition-to-ia",
            enabled: true,
            transitions: [
              {
                storageClass: s3.StorageClass.INFREQUENT_ACCESS,
                transitionAfter: cdk.Duration.days(90),
              },
            ],
          },
        ],
        removalPolicy:
          props.environment === "prod"
            ? cdk.RemovalPolicy.RETAIN
            : cdk.RemovalPolicy.DESTROY,
        autoDeleteObjects: props.environment !== "prod",
      });
      s3BucketName = storageBucket.bucketName;
      // IAM is granted after instance is created below
      // Store reference for grant call
      (this as any)._storageBucket = storageBucket;
    }

    // --- User Data ---
    const userData = ec2.UserData.forLinux();
    const script = readFileSync(
      join(__dirname, "../../scripts/userdata.sh"),
      "utf-8"
    );

    const envExports = [
      `export HUBZERO_DOMAIN="${domainName}"`,
      `export HUBZERO_CERTBOT_EMAIL="${certbotEmail}"`,
      `export HUBZERO_INSTALL_PLATFORM="${installPlatform}"`,
      `export HUBZERO_USE_RDS="${useRds}"`,
      `export HUBZERO_DB_HOST="${dbHost}"`,
      `export HUBZERO_DB_NAME="hubzero"`,
      `export HUBZERO_DB_USER="hubzero"`,
      `export HUBZERO_DB_SECRET_ARN="${dbSecretArn}"`,
      `export HUBZERO_ENABLE_MONITORING="${enableMonitoring}"`,
      `export HUBZERO_CW_LOG_GROUP_PREFIX="${logGroupPrefix}"`,
      `export HUBZERO_S3_BUCKET="${s3BucketName}"`,
    ];

    userData.addCommands(...envExports);
    userData.addCommands(script);

    // --- EC2 ---
    const instance = new ec2.Instance(this, "Instance", {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      associatePublicIpAddress: props.environment === "test",
      instanceType: new ec2.InstanceType(config.instanceType),
      machineImage: ami,
      securityGroup: sg,
      ssmSessionPermissions: true,
      requireImdsv2: true,
      keyPair: keyName
        ? ec2.KeyPair.fromKeyPairName(this, "KeyPair", keyName)
        : undefined,
      userData,
      blockDevices: [
        {
          deviceName: "/dev/sda1",
          volume: ec2.BlockDeviceVolume.ebs(config.volumeSize, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
          }),
        },
      ],
    });

    // Enable termination protection for prod
    if (props.environment === "prod") {
      (instance.node.defaultChild as ec2.CfnInstance).disableApiTermination =
        true;
    }

    // S3 file storage access
    if (enableS3Storage && (this as any)._storageBucket) {
      ((this as any)._storageBucket as s3.Bucket).grantReadWrite(instance.role);
    }

    // CloudWatch agent permissions (unconditional)
    instance.role.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: [
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
        ],
        resources: ["*"],
      })
    );

    // Grant EC2 read access to the RDS-managed secret
    if (useRds && dbInstance) {
      const cfnDb = dbInstance.node.defaultChild as rds.CfnDBInstance;
      instance.role.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["secretsmanager:GetSecretValue"],
          resources: [cfnDb.attrMasterUserSecretSecretArn],
        })
      );
    }

    // --- EBS Snapshot Lifecycle ---
    const dlmRole = new iam.Role(this, "DlmRole", {
      assumedBy: new iam.ServicePrincipal("dlm.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName(
          "service-role/AWSDataLifecycleManagerServiceRole"
        ),
      ],
    });

    const snapshotPolicy = new dlm.CfnLifecyclePolicy(
      this,
      "SnapshotPolicy",
      {
        description: `HubZero ${props.environment} daily EBS snapshots`,
        executionRoleArn: dlmRole.roleArn,
        state: "ENABLED",
        policyDetails: {
          resourceTypes: ["INSTANCE"],
          targetTags: [
            { key: "Name", value: `hubzero-${props.environment}` },
          ],
          schedules: [
            {
              name: "daily-snapshot",
              createRule: {
                interval: 24,
                intervalUnit: "HOURS",
                times: ["03:00"],
              },
              retainRule: { count: props.environment === "prod" ? 30 : 7 },
              tagsToAdd: [
                { key: "SnapshotCreator", value: "DLM" },
                { key: "Environment", value: props.environment },
              ],
            },
          ],
        },
      }
    );
    snapshotPolicy.applyRemovalPolicy(cdk.RemovalPolicy.RETAIN);

    // --- CloudWatch Monitoring ---
    if (enableMonitoring) {
      const logRemovalPolicy =
        props.environment === "prod"
          ? cdk.RemovalPolicy.RETAIN
          : cdk.RemovalPolicy.DESTROY;

      new logs.LogGroup(this, "LogGroupUserdata", {
        logGroupName: `${logGroupPrefix}/userdata`,
        retention: monConfig.logRetention,
        removalPolicy: logRemovalPolicy,
      });
      new logs.LogGroup(this, "LogGroupApacheAccess", {
        logGroupName: `${logGroupPrefix}/apache-access`,
        retention: monConfig.logRetention,
        removalPolicy: logRemovalPolicy,
      });
      new logs.LogGroup(this, "LogGroupApacheError", {
        logGroupName: `${logGroupPrefix}/apache-error`,
        retention: monConfig.logRetention,
        removalPolicy: logRemovalPolicy,
      });

      const alarmTopic = new sns.Topic(this, "AlarmTopic", {
        topicName: `hubzero-${props.environment}-alarms`,
      });
      if (alarmEmail) {
        alarmTopic.addSubscription(
          new snsSubscriptions.EmailSubscription(alarmEmail)
        );
      }
      const snsAction = new cloudwatchActions.SnsAction(alarmTopic);

      // EC2 alarms
      const ec2CpuAlarm = new cloudwatch.Alarm(this, "Ec2CpuAlarm", {
        alarmName: `hubzero-${props.environment}-ec2-cpu`,
        alarmDescription: `EC2 CPU utilization above ${monConfig.cpuThreshold}%`,
        metric: new cloudwatch.Metric({
          namespace: "AWS/EC2",
          metricName: "CPUUtilization",
          dimensionsMap: { InstanceId: instance.instanceId },
          period: monConfig.alarmPeriod,
          statistic: "Average",
        }),
        threshold: monConfig.cpuThreshold,
        evaluationPeriods: monConfig.evalPeriods,
        comparisonOperator:
          cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      });
      ec2CpuAlarm.addAlarmAction(snsAction);
      ec2CpuAlarm.addOkAction(snsAction);

      const ec2StatusAlarm = new cloudwatch.Alarm(this, "Ec2StatusAlarm", {
        alarmName: `hubzero-${props.environment}-ec2-status`,
        alarmDescription: "EC2 status check failed",
        metric: new cloudwatch.Metric({
          namespace: "AWS/EC2",
          metricName: "StatusCheckFailed",
          dimensionsMap: { InstanceId: instance.instanceId },
          period: cdk.Duration.seconds(60),
          statistic: "Maximum",
        }),
        threshold: 0,
        evaluationPeriods: 2,
        comparisonOperator:
          cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      });
      ec2StatusAlarm.addAlarmAction(snsAction);
      ec2StatusAlarm.addOkAction(snsAction);

      const ec2MemoryAlarm = new cloudwatch.Alarm(this, "Ec2MemoryAlarm", {
        alarmName: `hubzero-${props.environment}-ec2-memory`,
        alarmDescription: "EC2 memory usage above 80%",
        metric: new cloudwatch.Metric({
          namespace: "CWAgent",
          metricName: "mem_used_percent",
          dimensionsMap: { InstanceId: instance.instanceId },
          period: monConfig.alarmPeriod,
          statistic: "Average",
        }),
        threshold: 80,
        evaluationPeriods: monConfig.evalPeriods,
        comparisonOperator:
          cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      });
      ec2MemoryAlarm.addAlarmAction(snsAction);
      ec2MemoryAlarm.addOkAction(snsAction);

      const ec2DiskAlarm = new cloudwatch.Alarm(this, "Ec2DiskAlarm", {
        alarmName: `hubzero-${props.environment}-ec2-disk`,
        alarmDescription: "EC2 disk usage above 85%",
        metric: new cloudwatch.Metric({
          namespace: "CWAgent",
          metricName: "disk_used_percent",
          dimensionsMap: { InstanceId: instance.instanceId, path: "/" },
          period: monConfig.alarmPeriod,
          statistic: "Average",
        }),
        threshold: 85,
        evaluationPeriods: monConfig.evalPeriods,
        comparisonOperator:
          cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      });
      ec2DiskAlarm.addAlarmAction(snsAction);
      ec2DiskAlarm.addOkAction(snsAction);

      // RDS alarms (only if RDS is enabled)
      if (useRds && dbInstance) {
        const rdsCpuAlarm = new cloudwatch.Alarm(this, "RdsCpuAlarm", {
          alarmName: `hubzero-${props.environment}-rds-cpu`,
          alarmDescription: `RDS CPU utilization above ${monConfig.cpuThreshold}%`,
          metric: new cloudwatch.Metric({
            namespace: "AWS/RDS",
            metricName: "CPUUtilization",
            dimensionsMap: {
              DBInstanceIdentifier: dbInstance.instanceIdentifier,
            },
            period: monConfig.alarmPeriod,
            statistic: "Average",
          }),
          threshold: monConfig.cpuThreshold,
          evaluationPeriods: monConfig.evalPeriods,
          comparisonOperator:
            cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
        });
        rdsCpuAlarm.addAlarmAction(snsAction);
        rdsCpuAlarm.addOkAction(snsAction);

        const rdsConnectionsAlarm = new cloudwatch.Alarm(
          this,
          "RdsConnectionsAlarm",
          {
            alarmName: `hubzero-${props.environment}-rds-connections`,
            alarmDescription: "RDS connection count above 100",
            metric: new cloudwatch.Metric({
              namespace: "AWS/RDS",
              metricName: "DatabaseConnections",
              dimensionsMap: {
                DBInstanceIdentifier: dbInstance.instanceIdentifier,
              },
              period: monConfig.alarmPeriod,
              statistic: "Average",
            }),
            threshold: 100,
            evaluationPeriods: monConfig.evalPeriods,
            comparisonOperator:
              cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
          }
        );
        rdsConnectionsAlarm.addAlarmAction(snsAction);
        rdsConnectionsAlarm.addOkAction(snsAction);

        const rdsStorageAlarm = new cloudwatch.Alarm(this, "RdsStorageAlarm", {
          alarmName: `hubzero-${props.environment}-rds-storage`,
          alarmDescription: "RDS free storage below 5 GB",
          metric: new cloudwatch.Metric({
            namespace: "AWS/RDS",
            metricName: "FreeStorageSpace",
            dimensionsMap: {
              DBInstanceIdentifier: dbInstance.instanceIdentifier,
            },
            period: monConfig.alarmPeriod,
            statistic: "Average",
          }),
          threshold: 5368709120,
          evaluationPeriods: monConfig.evalPeriods,
          comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
        });
        rdsStorageAlarm.addAlarmAction(snsAction);
        rdsStorageAlarm.addOkAction(snsAction);
      }

      new cdk.CfnOutput(this, "SnsTopicArn", {
        description: "SNS topic ARN for CloudWatch alarms",
        value: alarmTopic.topicArn,
      });
    }

    // --- Tags & Outputs ---
    cdk.Tags.of(this).add("Project", "hubzero");
    cdk.Tags.of(this).add("Environment", props.environment);
    cdk.Tags.of(this).add("ManagedBy", "cdk");

    new cdk.CfnOutput(this, "InstanceId", { value: instance.instanceId });
    new cdk.CfnOutput(this, "PublicIp", {
      value: instance.instancePublicIp,
    });
    new cdk.CfnOutput(this, "WebUrl", {
      value:
        domainName !== ""
          ? `https://${domainName}`
          : `http://${instance.instancePublicIp}`,
    });
    new cdk.CfnOutput(this, "SsmConnect", {
      value: `aws ssm start-session --target ${instance.instanceId}`,
    });
    if (useRds && dbInstance) {
      new cdk.CfnOutput(this, "RdsEndpoint", {
        value: dbInstance.dbInstanceEndpointAddress,
      });
    }
  }
}
