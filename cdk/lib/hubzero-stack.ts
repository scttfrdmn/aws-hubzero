import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as rds from "aws-cdk-lib/aws-rds";
import * as dlm from "aws-cdk-lib/aws-dlm";
import * as iam from "aws-cdk-lib/aws-iam";
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

    const ami = ec2.MachineImage.lookup({
      name: "Rocky-8-EC2-Base-8.*-x86_64-*",
      owners: ["792107900819"],
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
