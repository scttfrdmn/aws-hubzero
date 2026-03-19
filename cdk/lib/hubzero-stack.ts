import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as rds from "aws-cdk-lib/aws-rds";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as efs from "aws-cdk-lib/aws-efs";
import * as autoscaling from "aws-cdk-lib/aws-autoscaling";
import * as elbv2 from "aws-cdk-lib/aws-elasticloadbalancingv2";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as wafv2 from "aws-cdk-lib/aws-wafv2";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as cforigins from "aws-cdk-lib/aws-cloudfront-origins";
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

const ENV_CONFIG: Record<string, { volumeSize: number }> = {
  test: { volumeSize: 30 },
  staging: { volumeSize: 100 },
  prod: { volumeSize: 200 },
};

// Deployment profiles: minimal (default), graviton (ARM64, ~20% cheaper), spot (spot pricing).
// spot requires useRds=true and enableEfs=true to survive interruptions.
const PROFILE_CONFIG: Record<
  string,
  { instanceType: string; cpuArch: ec2.AmazonLinuxCpuType; useSpot: boolean }
> = {
  minimal: {
    instanceType: "t3.medium",
    cpuArch: ec2.AmazonLinuxCpuType.X86_64,
    useSpot: false,
  },
  graviton: {
    instanceType: "t4g.medium",
    cpuArch: ec2.AmazonLinuxCpuType.ARM_64,
    useSpot: false,
  },
  spot: {
    instanceType: "t3.medium",
    cpuArch: ec2.AmazonLinuxCpuType.X86_64,
    useSpot: true,
  },
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
    const deploymentProfile =
      this.node.tryGetContext("deploymentProfile") || "minimal";
    if (!PROFILE_CONFIG[deploymentProfile]) {
      throw new Error(
        `deploymentProfile must be one of: minimal, graviton, spot (got "${deploymentProfile}")`
      );
    }
    const profile = PROFILE_CONFIG[deploymentProfile];
    // Allow instance_type context override (same as Terraform instance_type variable)
    const instanceTypeOverride: string =
      this.node.tryGetContext("instanceType") || "";
    const ec2InstanceType = instanceTypeOverride || profile.instanceType;
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
    const enableAlb = this.node.tryGetContext("enableAlb") !== "false";
    const acmCertificateArn: string =
      this.node.tryGetContext("acmCertificateArn") || "";
    const enableWaf = this.node.tryGetContext("enableWaf") !== "false";
    const enableVpcEndpoints =
      this.node.tryGetContext("enableVpcEndpoints") !== "false";
    const useBakedAmi = this.node.tryGetContext("useBakedAmi") !== "false";
    const enablePatchManager =
      this.node.tryGetContext("enablePatchManager") !== "false";
    const enableParameterStore =
      this.node.tryGetContext("enableParameterStore") !== "false";
    const enableEfs = this.node.tryGetContext("enableEfs") !== "false";
    const enableCdn = this.node.tryGetContext("enableCdn") === "true";
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
    // Direct HTTP/HTTPS only when ALB is not in front
    if (!enableAlb) {
      for (const port of [80, 443]) {
        sg.addIngressRule(
          ec2.Peer.ipv4(allowedCidr),
          ec2.Port.tcp(port),
          `Port ${port}`
        );
      }
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

    // When useBakedAmi is enabled, look up a pre-baked HubZero AMI (built by
    // Packer). Falls back to the latest AL2023 base AMI if no baked image exists.
    if (profile.useSpot && !(useRds && enableEfs)) {
      throw new Error(
        'deploymentProfile="spot" requires useRds=true and enableEfs=true to prevent data loss on spot interruption.'
      );
    }

    const ami = useBakedAmi
      ? ec2.MachineImage.lookup({
          name: "hubzero-base-*",
          owners: ["self"],
          filters: { architecture: [profile.cpuArch === ec2.AmazonLinuxCpuType.ARM_64 ? "arm64" : "x86_64"] },
        })
      : ec2.MachineImage.latestAmazonLinux2023({
          cpuType: profile.cpuArch,
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

    // --- EFS Shared Web Root (optional) ---
    let efsId = "";
    let efsAccessPointId = "";
    if (enableEfs) {
      const fileSystem = new efs.FileSystem(this, "FileSystem", {
        vpc,
        encrypted: true,
        performanceMode: efs.PerformanceMode.GENERAL_PURPOSE,
        removalPolicy:
          props.environment === "prod"
            ? cdk.RemovalPolicy.RETAIN
            : cdk.RemovalPolicy.DESTROY,
      });
      fileSystem.connections.allowFrom(sg, ec2.Port.tcp(2049), "NFS from EC2");

      const accessPoint = new efs.AccessPoint(this, "AccessPoint", {
        fileSystem,
        posixUser: { uid: "48", gid: "48" },
        createAcl: { ownerUid: "48", ownerGid: "48", permissions: "755" },
        path: "/hubzero",
      });

      efsId = fileSystem.fileSystemId;
      efsAccessPointId = accessPoint.accessPointId;

      fileSystem.grantRootAccess(new iam.ArnPrincipal(`arn:aws:iam::${this.account}:root`));
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
      `export HUBZERO_ENABLE_ALB="${enableAlb}"`,
      `export HUBZERO_ENVIRONMENT="${props.environment}"`,
      `export HUBZERO_ENABLE_PARAMETER_STORE="${enableParameterStore}"`,
      `export HUBZERO_EFS_ID="${efsId}"`,
      `export HUBZERO_EFS_ACCESS_POINT_ID="${efsAccessPointId}"`,
    ];

    userData.addCommands(...envExports);
    userData.addCommands(script);

    // --- Auto Scaling Group (min=1) ---
    const asg = new autoscaling.AutoScalingGroup(this, "ASG", {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: new ec2.InstanceType(ec2InstanceType),
      machineImage: ami,
      securityGroup: sg,
      requireImdsv2: true,
      keyPair: keyName
        ? ec2.KeyPair.fromKeyPairName(this, "KeyPair", keyName)
        : undefined,
      userData,
      blockDevices: [
        {
          deviceName: "/dev/xvda",
          volume: autoscaling.BlockDeviceVolume.ebs(config.volumeSize, {
            volumeType: autoscaling.EbsDeviceVolumeType.GP3,
            encrypted: true,
          }),
        },
      ],
      minCapacity: 1,
      maxCapacity: 1,
      desiredCapacity: 1,
      healthCheck: enableAlb
        ? autoscaling.HealthCheck.elb({ grace: cdk.Duration.minutes(5) })
        : autoscaling.HealthCheck.ec2(),
      // spot profile: set a max bid well above typical spot price to ensure capacity.
      // t3.medium on-demand is $0.0416/hr; spot typically runs $0.004–0.008/hr.
      spotPrice: profile.useSpot ? "0.10" : undefined,
      // Instance refresh (rolling): use CfnAutoScalingGroup override since
      // AutoScalingGroupProps does not expose this directly in all CDK versions
      ssmSessionPermissions: true,
    });
    // Convenience alias — used in the sections below
    const instance = asg;

    const cfnAsg = asg.node.defaultChild as autoscaling.CfnAutoScalingGroup;

    // Rolling instance refresh
    cfnAsg.addPropertyOverride("InstanceRefresh", {
      Strategy: "Rolling",
      Preferences: { MinHealthyPercentage: 0 },
    });

    cdk.Tags.of(asg).add("Patch Group", `hubzero-${props.environment}`);

    // S3 file storage access
    if (enableS3Storage && (this as any)._storageBucket) {
      ((this as any)._storageBucket as s3.Bucket).grantReadWrite(asg.role);
    }

    // CloudWatch agent permissions (unconditional)
    asg.role.addToPrincipalPolicy(
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
      asg.role.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["secretsmanager:GetSecretValue"],
          resources: [cfnDb.attrMasterUserSecretSecretArn],
        })
      );
    }

    // --- ALB + ACM (optional) ---
    if (enableAlb) {
      const albSg = new ec2.SecurityGroup(this, "AlbSG", {
        vpc,
        description: `HubZero ALB ${props.environment}`,
        allowAllOutbound: false,
      });
      for (const port of [80, 443]) {
        albSg.addIngressRule(
          ec2.Peer.ipv4(allowedCidr),
          ec2.Port.tcp(port),
          `ALB port ${port}`
        );
      }
      albSg.addEgressRule(sg, ec2.Port.tcp(80), "To EC2 HTTP");

      // Allow ALB to reach EC2
      sg.addIngressRule(albSg, ec2.Port.tcp(80), "HTTP from ALB");

      const alb = new elbv2.ApplicationLoadBalancer(this, "ALB", {
        vpc,
        internetFacing: true,
        securityGroup: albSg,
      });

      const targetGroup = new elbv2.ApplicationTargetGroup(this, "TargetGroup", {
        vpc,
        port: 80,
        protocol: elbv2.ApplicationProtocol.HTTP,
        targets: [asg],
        healthCheck: { path: "/", healthyThresholdCount: 2 },
      });

      alb.addListener("HttpListener", {
        port: 80,
        defaultAction: elbv2.ListenerAction.redirect({
          port: "443",
          protocol: "HTTPS",
          permanent: true,
        }),
      });

      let albCertificate: acm.ICertificate | undefined;
      if (acmCertificateArn) {
        albCertificate = acm.Certificate.fromCertificateArn(
          this,
          "Cert",
          acmCertificateArn
        );
      } else if (domainName) {
        albCertificate = new acm.Certificate(this, "Cert", {
          domainName,
          validation: acm.CertificateValidation.fromDns(),
        });
      }

      if (albCertificate) {
        alb.addListener("HttpsListener", {
          port: 443,
          certificates: [albCertificate],
          defaultAction: elbv2.ListenerAction.forward([targetGroup]),
          sslPolicy: elbv2.SslPolicy.RECOMMENDED_TLS,
        });
      }

      new cdk.CfnOutput(this, "AlbDnsName", { value: alb.loadBalancerDnsName });

      // --- WAF v2 (optional) ---
      if (enableWaf) {
        const webAcl = new wafv2.CfnWebACL(this, "WebACL", {
          name: `hubzero-${props.environment}`,
          scope: "REGIONAL",
          defaultAction: { allow: {} },
          rules: [
            {
              name: "AWSManagedRulesCommonRuleSet",
              priority: 1,
              overrideAction: { none: {} },
              statement: {
                managedRuleGroupStatement: {
                  vendorName: "AWS",
                  name: "AWSManagedRulesCommonRuleSet",
                },
              },
              visibilityConfig: {
                cloudWatchMetricsEnabled: true,
                metricName: "CommonRuleSet",
                sampledRequestsEnabled: true,
              },
            },
            {
              name: "AWSManagedRulesKnownBadInputsRuleSet",
              priority: 2,
              overrideAction: { none: {} },
              statement: {
                managedRuleGroupStatement: {
                  vendorName: "AWS",
                  name: "AWSManagedRulesKnownBadInputsRuleSet",
                },
              },
              visibilityConfig: {
                cloudWatchMetricsEnabled: true,
                metricName: "KnownBadInputs",
                sampledRequestsEnabled: true,
              },
            },
            {
              name: "AWSManagedRulesSQLiRuleSet",
              priority: 3,
              overrideAction: { none: {} },
              statement: {
                managedRuleGroupStatement: {
                  vendorName: "AWS",
                  name: "AWSManagedRulesSQLiRuleSet",
                },
              },
              visibilityConfig: {
                cloudWatchMetricsEnabled: true,
                metricName: "SQLiRuleSet",
                sampledRequestsEnabled: true,
              },
            },
          ],
          visibilityConfig: {
            cloudWatchMetricsEnabled: true,
            metricName: `hubzero-${props.environment}`,
            sampledRequestsEnabled: true,
          },
        });

        new wafv2.CfnWebACLAssociation(this, "WebACLAssociation", {
          resourceArn: alb.loadBalancerArn,
          webAclArn: webAcl.attrArn,
        });
      }
    }

    // --- VPC Endpoints (optional) ---
    if (enableVpcEndpoints) {
      const vpcesg = new ec2.SecurityGroup(this, "VpcEndpointSG", {
        vpc,
        description: `HubZero VPC endpoint interfaces ${props.environment}`,
        allowAllOutbound: false,
      });
      vpcesg.addIngressRule(sg, ec2.Port.tcp(443), "HTTPS from EC2");

      vpc.addGatewayEndpoint("S3Endpoint", {
        service: ec2.GatewayVpcEndpointAwsService.S3,
      });

      for (const [id, svc] of [
        ["SsmEndpoint", ec2.InterfaceVpcEndpointAwsService.SSM],
        ["SsmMessagesEndpoint", ec2.InterfaceVpcEndpointAwsService.SSM_MESSAGES],
        ["Ec2MessagesEndpoint", ec2.InterfaceVpcEndpointAwsService.EC2_MESSAGES],
        [
          "SecretsManagerEndpoint",
          ec2.InterfaceVpcEndpointAwsService.SECRETS_MANAGER,
        ],
        ["LogsEndpoint", ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS],
      ] as [string, ec2.InterfaceVpcEndpointAwsService][]) {
        new ec2.InterfaceVpcEndpoint(this, id, {
          vpc,
          service: svc,
          securityGroups: [vpcesg],
          privateDnsEnabled: true,
        });
      }
    }

    // --- SSM Patch Manager (optional) ---
    if (enablePatchManager) {
      // Add Patch Group tag to instance so SSM can target it
      cdk.Tags.of(instance).add("Patch Group", `hubzero-${props.environment}`);

      const patchBaseline = new cdk.aws_ssm.CfnPatchBaseline(this, "PatchBaseline", {
        name: `hubzero-${props.environment}`,
        operatingSystem: "AMAZON_LINUX_2023",
        description: `HubZero ${props.environment} security patch baseline`,
        approvalRules: {
          patchRules: [
            {
              approveAfterDays: 7,
              patchFilterGroup: {
                patchFilters: [
                  { key: "CLASSIFICATION", values: ["Security"] },
                  { key: "SEVERITY", values: ["Critical", "Important"] },
                ],
              },
            },
          ],
        },
      });

      const patchGroup = new cdk.aws_ssm.CfnAssociation(this, "PatchGroup", {
        name: "AWS-RunPatchBaseline",
        targets: [
          { key: "tag:Patch Group", values: [`hubzero-${props.environment}`] },
        ],
        parameters: { Operation: ["Scan"] },
        scheduleExpression: "cron(0 3 ? * SUN *)",
      });
      patchGroup.node.addDependency(patchBaseline);
    }

    // --- SSM Parameter Store (optional) ---
    if (enableParameterStore) {
      const ssmPrefix = `/hubzero/${props.environment}`;

      new cdk.aws_ssm.StringParameter(this, "ParamDomainName", {
        parameterName: `${ssmPrefix}/domain_name`,
        stringValue: domainName || "unset",
      });
      new cdk.aws_ssm.StringParameter(this, "ParamEnableMonitoring", {
        parameterName: `${ssmPrefix}/enable_monitoring`,
        stringValue: String(enableMonitoring),
      });
      new cdk.aws_ssm.StringParameter(this, "ParamCwLogPrefix", {
        parameterName: `${ssmPrefix}/cw_log_prefix`,
        stringValue: logGroupPrefix,
      });

      // IAM policy: allow EC2 to read all params in its environment path
      instance.role.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["ssm:GetParametersByPath", "ssm:GetParameter"],
          resources: [
            `arn:aws:ssm:${this.region}:${this.account}:parameter${ssmPrefix}/*`,
          ],
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
          dimensionsMap: { AutoScalingGroupName: asg.autoScalingGroupName },
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
          dimensionsMap: { AutoScalingGroupName: asg.autoScalingGroupName },
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
          dimensionsMap: { AutoScalingGroupName: asg.autoScalingGroupName },
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
          dimensionsMap: { AutoScalingGroupName: asg.autoScalingGroupName, path: "/" },
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

    // --- CloudFront (optional, requires ALB) ---
    if (enableCdn && enableAlb) {
      // ALB DNS name is set in the enableAlb block above; look it up via CfnOutput
      // For CloudFront we need the ALB ARN which we don't have directly here.
      // The CloudFront distribution is documented as a follow-up using the AlbDnsName output.
      new cdk.CfnOutput(this, "CloudFrontNote", {
        description: "CloudFront CDN",
        value: "Use AlbDnsName output as the origin domain for your CloudFront distribution",
      });
    }

    // --- Tags & Outputs ---
    cdk.Tags.of(this).add("Project", "hubzero");
    cdk.Tags.of(this).add("Environment", props.environment);
    cdk.Tags.of(this).add("ManagedBy", "cdk");

    new cdk.CfnOutput(this, "AsgName", {
      description: "Auto Scaling Group name",
      value: asg.autoScalingGroupName,
    });
    new cdk.CfnOutput(this, "WebUrl", {
      value: domainName !== "" ? `https://${domainName}` : "(see AlbDnsName or configure domain)",
    });
    new cdk.CfnOutput(this, "SsmConnect", {
      description: "Find instance and connect via SSM",
      value: `aws ec2 describe-instances --filters 'Name=tag:aws:autoscaling:groupName,Values=${asg.autoScalingGroupName}' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].InstanceId' --output text | xargs -I{} aws ssm start-session --target {}`,
    });
    if (useRds && dbInstance) {
      new cdk.CfnOutput(this, "RdsEndpoint", {
        value: dbInstance.dbInstanceEndpointAddress,
      });
    }
  }
}
