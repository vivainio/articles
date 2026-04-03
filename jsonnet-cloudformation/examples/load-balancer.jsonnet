// Example: Internal ALB with target-group + listener pair factory
//
// A cluster with three node types (AppServer, JobRunner, Gateway) each
// needs an internal ALB with 1–4 target groups. Without abstraction,
// every TargetGroup + Listener pair is copy-pasted per port — a
// four-port JobRunner ALB means eight near-identical resource blocks
// (4 TGs + 4 listeners = ~120 lines of JSON).
//
// Patterns demonstrated:
//
// 1. tgPair() factory — one call produces a matching TargetGroup +
//    Listener, wired to the parent ALB, with health-check defaults.
// 2. internalAlb() — assembles the ALB + security group + N target
//    group pairs from a compact config. Returns a handle object with
//    resource refs for wiring into ASGs.
// 3. Access-log attributes — optional S3 access-log configuration
//    folded into load-balancer attributes when a log prefix is given.

local cfn = import '../lib/cfn.libsonnet';

local stage = std.extVar('stage');

// ── Target-group + listener pair factory ──────────────────────────────
// Without this, every port needs two hand-written resources — a
// TargetGroup and a Listener — with identical structure. Four ports
// means eight blocks that differ only in port number and deregistration
// delay.

local tgPair(prefix, albLogical, n, port, cfg) = {
  local tgLogical = prefix + 'Tg' + n,
  local listenerLogical = prefix + 'Tg' + n + 'Listener',

  resources: {
    [tgLogical]: {
      Type: 'AWS::ElasticLoadBalancingV2::TargetGroup',
      Properties: {
        Name: cfn.sub('${AWS::StackName}-' + prefix + '-' + n),
        Port: port,
        Protocol: cfg.protocol,
        TargetType: 'instance',
        VpcId: cfg.vpcId,
        HealthCheckEnabled: true,
        HealthCheckPort: std.toString(cfg.healthCheckPort),
        HealthCheckProtocol: 'HTTP',
        HealthCheckIntervalSeconds: 30,
        HealthCheckTimeoutSeconds: 15,
        HealthyThresholdCount: 2,
        UnhealthyThresholdCount: 2,
        TargetGroupAttributes: [
          { Key: 'deregistration_delay.timeout_seconds', Value: std.toString(cfg.deregDelay) },
        ],
      } + (if cfg.tags != [] then { Tags: cfg.tags } else {}),
    },
    [listenerLogical]: {
      Type: 'AWS::ElasticLoadBalancingV2::Listener',
      Properties: {
        LoadBalancerArn: cfn.ref(albLogical),
        Port: port,
        Protocol: cfg.protocol,
        DefaultActions: [{ Type: 'forward', TargetGroupArn: cfn.ref(tgLogical) }],
      } + (if cfg.protocol == 'HTTPS' then {
             Certificates: [{ CertificateArn: cfg.certificateArn }],
             SslPolicy: 'ELBSecurityPolicy-TLS13-1-2-2021-06',
           } else {}),
    },
  },

  tgRef: cfn.ref(tgLogical),
};


// ── Internal ALB factory ──────────────────────────────────────────────
// Bundles the load balancer, security group, and N target-group pairs
// into a single call. Returns { resources, albRef, tgArns } so the
// caller can wire the TG ARNs into an ASG.

local internalAlb(cfg) =
  local albLogical = cfg.prefix + 'Alb';
  local sgLogical = cfg.prefix + 'AlbSg';

  // Access-log attributes — only added when logPrefix is set
  local accessLogAttrs =
    if std.objectHas(cfg, 'logPrefix') then [
      { Key: 'access_logs.s3.enabled', Value: 'true' },
      { Key: 'access_logs.s3.bucket', Value: cfg.logBucket },
      { Key: 'access_logs.s3.prefix', Value: cfg.logPrefix },
    ] else [];

  // Build all TG pairs
  local pairs = [
    tgPair(cfg.prefix, albLogical, std.toString(i + 1), cfg.ports[i].port, {
      protocol: std.get(cfg.ports[i], 'protocol', 'HTTP'),
      deregDelay: std.get(cfg.ports[i], 'deregDelay', 300),
      healthCheckPort: std.get(cfg.ports[i], 'healthCheckPort', cfg.ports[i].port),
      certificateArn: std.get(cfg, 'certificateArn', ''),
      vpcId: cfg.vpcId,
      tags: std.get(cfg, 'tags', []),
    })
    for i in std.range(0, std.length(cfg.ports) - 1)
  ];

  {
    resources: {
                 // Security group for the ALB
                 [sgLogical]: {
                   Type: 'AWS::EC2::SecurityGroup',
                   Properties: {
                     GroupDescription: cfg.prefix + ' ALB',
                     VpcId: cfg.vpcId,
                     SecurityGroupIngress: cfg.ingress,
                   } + (if std.get(cfg, 'tags', []) != [] then { Tags: cfg.tags } else {}),
                 },

                 // The ALB itself
                 [albLogical]: {
                   Type: 'AWS::ElasticLoadBalancingV2::LoadBalancer',
                   Properties: {
                     Name: cfn.sub('${AWS::StackName}-' + cfg.prefix),
                     Scheme: 'internal',
                     Type: 'application',
                     SecurityGroups: [cfn.ref(sgLogical)],
                     Subnets: cfg.subnets,
                     LoadBalancerAttributes:
                       [{ Key: 'idle_timeout.timeout_seconds', Value: std.toString(std.get(cfg, 'idleTimeout', 60)) }]
                       + accessLogAttrs,
                   } + (if std.get(cfg, 'tags', []) != [] then { Tags: cfg.tags } else {}),
                 },
               }

               // Merge in all target-group + listener pairs
               + std.foldl(function(acc, pair) acc + pair.resources, pairs, {}),

    // Handles for wiring into ASG / outputs
    albRef: cfn.ref(albLogical),
    sgRef: cfn.ref(sgLogical),
    dnsName: cfn.getAtt(albLogical, 'DNSName'),
    tgArns: [p.tgRef for p in pairs],
  };


// ── Service definitions ───────────────────────────────────────────────
// Three node types sharing the same factory — only the port lists and
// a few options differ.

local vpcId = cfn.ref('VpcId');

local tags = cfn.tags({
  Application: 'MyApp',
  Environment: stage,
});

local appServerAlb = internalAlb({
  prefix: 'AppServer',
  vpcId: vpcId,
  subnets: [cfn.ref('PrivateSubnetA'), cfn.ref('PrivateSubnetB')],
  idleTimeout: 300,
  certificateArn: cfn.ref('CertificateArn'),
  logBucket: cfn.sub('${AccountAbbr}-${RegionCode}-logs'),
  logPrefix: 'elb-access/app-server',
  tags: tags,
  ingress: [
    { IpProtocol: 'tcp', FromPort: 443, ToPort: 443, CidrIp: cfn.ref('VpcCidr') },
  ],
  ports: [
    { port: 443, protocol: 'HTTPS', deregDelay: 600, healthCheckPort: 5001 },
  ],
});

local jobRunnerAlb = internalAlb({
  prefix: 'JobRunner',
  vpcId: vpcId,
  subnets: [cfn.ref('PrivateSubnetA'), cfn.ref('PrivateSubnetB')],
  idleTimeout: 600,
  tags: tags,
  ingress: [
    { IpProtocol: 'tcp', FromPort: 8008, ToPort: 8879, CidrIp: cfn.ref('VpcCidr') },
  ],
  ports: [
    { port: 8008, deregDelay: 600, healthCheckPort: 5001 },
    { port: 8055, healthCheckPort: 5001 },
    { port: 8058, healthCheckPort: 5001 },
    { port: 8879, healthCheckPort: 5001 },
  ],
});

local gatewayAlb = internalAlb({
  prefix: 'Gateway',
  vpcId: vpcId,
  subnets: [cfn.ref('PrivateSubnetA'), cfn.ref('PrivateSubnetB')],
  tags: tags,
  ingress: [
    { IpProtocol: 'tcp', FromPort: 8080, ToPort: 8080, CidrIp: cfn.ref('VpcCidr') },
  ],
  ports: [
    { port: 8080, healthCheckPort: 5001 },
  ],
});


// ── Template ──────────────────────────────────────────────────────────

{
  AWSTemplateFormatVersion: '2010-09-09',
  Description: 'Internal ALBs (' + stage + ') — AppServer, JobRunner, Gateway',

  Parameters: {
    VpcId: cfn.param(description='VPC ID'),
    VpcCidr: cfn.param(description='VPC CIDR block'),
    CertificateArn: cfn.param(description='ACM certificate ARN for HTTPS listeners'),
    PrivateSubnetA: cfn.param(description='First private subnet'),
    PrivateSubnetB: cfn.param(description='Second private subnet'),
    AccountAbbr: cfn.param(description='Account abbreviation (lowercase)'),
    RegionCode: cfn.param(description='Region code (lowercase)'),
  },

  Resources:
    appServerAlb.resources
    + jobRunnerAlb.resources
    + gatewayAlb.resources,

  Outputs: {
    AppServerAlbDns: cfn.output(appServerAlb.dnsName),
    JobRunnerAlbDns: cfn.output(jobRunnerAlb.dnsName),
    GatewayAlbDns: cfn.output(gatewayAlb.dnsName),

    // JobRunner TG ARNs — comma-separated for cross-stack import
    JobRunnerTargetGroups: cfn.output(
      cfn.join(',', jobRunnerAlb.tgArns)
    ),
  },
}
