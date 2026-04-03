// Example: Config-driven CloudFront + S3 static site hosting
//
// A common CDK pattern: one Stack class instantiated 5 times from
// different config objects — each with its own bucket prefix, domain
// template, CloudFront function, etc. CDK wraps this in a TypeScript
// class with a 10-field interface. In Jsonnet, the same pattern is a
// local function that returns a resources object, called in a loop.
//
// Patterns demonstrated:
//
// 1. staticSite() factory — S3 bucket + OAC + CloudFront distribution +
//    CloudFront Function + bucket policy, wired together
// 2. Config-driven multi-site — array of site configs iterated with
//    std.foldl to merge all resources
// 3. Domain name generation from region/stage lookup tables
// 4. Mandatory + optional tagging via a tag helper

local cfn = import '../lib/cfn.libsonnet';

local stage = std.extVar('stage');

// ── Lookup tables ──────────────────────────────────────────────────────────
// CDK typically puts these in a shared lib with getter functions.
// In Jsonnet they're just objects — no boilerplate needed.

local mainStages = {
  dev: 'dev',
  preqa: 'qa',
  qa: 'qa',
  preprod: 'prod',
  prod: 'prod',
};
local mainStage = if std.objectHas(mainStages, stage) then mainStages[stage] else 'dev';

local domains = {
  dev: 'example-dev.com',
  qa: 'example-qa.com',
  prod: 'example.com',
};
local domain = domains[mainStage];

local regionCodes = {
  dev: ['dub'],
  qa: ['dub', 'pdx'],
  prod: ['dub', 'pdx'],
};

// ── Tag helper ─────────────────────────────────────────────────────────────
// Mandatory tags on every resource, with optional compliance flags.

local siteTags(name, role, extra={}) =
  cfn.tags({
    Name: name,
    Role: role,
    Application: 'MyApp',
    StagingArea: stage,
    Owner: 'Platform',
    Environment: stage,
  } + extra);

// ── Static site factory ────────────────────────────────────────────────────
// Given a config object, produces all CloudFormation resources for an
// S3-backed CloudFront site: private bucket, OAC, distribution with
// CloudFront Function, and a bucket policy granting CloudFront access.
//
// The CDK equivalent is a 200-line Stack subclass. Here it's ~80 lines
// of pure data, called once per site.

local staticSite(cfg) =
  local prefix = cfg.prefix;
  local bucketName = cfg.bucketPrefix + stage;
  local bucketLogical = prefix + 'Bucket';
  local distLogical = prefix + 'Distribution';
  local oacLogical = prefix + 'OAC';
  local cfFnLogical = prefix + 'CfFunction';
  local policyLogical = prefix + 'BucketPolicy';

  // Domain names: expand template for each region code
  local domainNames = [
    std.strReplace(
      std.strReplace(
        std.strReplace(cfg.domainTemplate, '{region}', r),
        '{stage}',
        stage,
      ),
      '{domain}',
      cfg.siteDomain,
    )
    for r in regionCodes[mainStage]
  ];

  {
    // Private S3 bucket — no public access
    [bucketLogical]: {
      Type: 'AWS::S3::Bucket',
      DeletionPolicy: 'Delete',
      Properties: {
        BucketName: bucketName,
        PublicAccessBlockConfiguration: {
          BlockPublicAcls: true,
          BlockPublicPolicy: true,
          IgnorePublicAcls: true,
          RestrictPublicBuckets: true,
        },
        Tags: siteTags(bucketName, cfg.bucketTagRole, {
          DataClassification: 'Restricted',
          Encrypted: 'True',
        }),
      },
    },

    // Origin Access Control — CloudFront signs requests to S3
    [oacLogical]: {
      Type: 'AWS::CloudFront::OriginAccessControl',
      Properties: {
        OriginAccessControlConfig: {
          Name: prefix + '-oac-' + stage,
          OriginAccessControlOriginType: 's3',
          SigningBehavior: 'always',
          SigningProtocol: 'sigv4',
        },
      },
    },

    // CloudFront Function — SPA routing (rewrite paths to index.html)
    [cfFnLogical]: {
      Type: 'AWS::CloudFront::Function',
      Properties: {
        Name: cfg.cfFunctionName + stage,
        AutoPublish: true,
        FunctionConfig: {
          Comment: prefix + ' SPA router',
          Runtime: 'cloudfront-js-2.0',
        },
        // In practice, load from a file via std.importstr
        FunctionCode: |||
          function handler(event) {
            var request = event.request;
            var uri = request.uri;
            if (uri.endsWith('/')) {
              request.uri += 'index.html';
            } else if (!uri.includes('.')) {
              request.uri += '/index.html';
            }
            return request;
          }
        |||,
      },
    },

    // CloudFront Distribution
    [distLogical]: {
      Type: 'AWS::CloudFront::Distribution',
      Properties: {
        DistributionConfig: {
          Enabled: true,
          DefaultRootObject: 'index.html',
          HttpVersion: 'http2and3',

          // Domain names + certificate
          Aliases: domainNames,
          ViewerCertificate: {
            // Certificate ARN from SSM — each site has its own param
            AcmCertificateArn: '{{resolve:ssm:' + cfg.certificateParam + '}}',
            SslSupportMethod: 'sni-only',
            MinimumProtocolVersion: 'TLSv1.2_2021',
          },

          // Default behavior: S3 via OAC + CloudFront Function
          DefaultCacheBehavior: {
            TargetOriginId: bucketLogical,
            ViewerProtocolPolicy: 'redirect-to-https',
            CachePolicyId: '658327ea-f89d-4fab-a63d-7e88639e58f6',  // CachingOptimized
            FunctionAssociations: [{
              EventType: 'viewer-request',
              FunctionARN: cfn.getAtt(cfFnLogical, 'FunctionARN'),
            }],
          },

          Origins: [{
            Id: bucketLogical,
            DomainName: cfn.getAtt(bucketLogical, 'RegionalDomainName'),
            OriginAccessControlId: cfn.getAtt(oacLogical, 'Id'),
            S3OriginConfig: {
              OriginAccessIdentity: '',
            },
          }],

          // SPA: return index.html for 404s
          CustomErrorResponses: [{
            ErrorCode: 403,
            ResponseCode: 200,
            ResponsePagePath: '/index.html',
            ErrorCachingMinTTL: 10,
          }, {
            ErrorCode: 404,
            ResponseCode: 200,
            ResponsePagePath: '/index.html',
            ErrorCachingMinTTL: 10,
          }],
        },
        Tags: siteTags(prefix + '-cdn-' + stage, cfg.cfTagRole),
      },
    },

    // Bucket policy — allow CloudFront OAC to read objects
    [policyLogical]: {
      Type: 'AWS::S3::BucketPolicy',
      Properties: {
        Bucket: cfn.ref(bucketLogical),
        PolicyDocument: {
          Version: '2012-10-17',
          Statement: [{
            Sid: 'AllowCloudFrontOAC',
            Effect: 'Allow',
            Principal: { Service: 'cloudfront.amazonaws.com' },
            Action: 's3:GetObject',
            Resource: cfn.sub('arn:${AWS::Partition}:s3:::' + bucketName + '/*'),
            Condition: {
              StringEquals: {
                'AWS:SourceArn': cfn.sub(
                  'arn:${AWS::Partition}:cloudfront::${AWS::AccountId}:distribution/${' + distLogical + '}'
                ),
              },
            },
          }],
        },
      },
    },
  };

// ── Site configs ───────────────────────────────────────────────────────────
// In CDK these are 5 blocks of ~12 lines each in the bin/cdk.ts entrypoint.
// Here they're array elements fed to the factory.

local sites = [
  {
    prefix: 'MainUi',
    bucketPrefix: 'app-ui-',
    cfFunctionName: 'app-ui-router-',
    certificateParam: '/app/' + stage + '/ui/certificate',
    siteDomain: 'app.' + domain,
    domainTemplate: '*.{region}-{stage}.{domain}',
    bucketTagRole: 'AppBucket',
    cfTagRole: 'AppCdn',
  },
  {
    prefix: 'AdminUi',
    bucketPrefix: 'app-adminui-',
    cfFunctionName: 'app-admin-router-',
    certificateParam: '/app/' + stage + '/admin/certificate',
    siteDomain: 'app-admin.' + domain,
    domainTemplate: '*.{region}-{stage}.{domain}',
    bucketTagRole: 'AdminBucket',
    cfTagRole: 'AdminCdn',
  },
  {
    prefix: 'PortalUi',
    bucketPrefix: 'portal-ui-',
    cfFunctionName: 'portal-router-',
    certificateParam: '/portal/' + stage + '/ui/certificate',
    siteDomain: 'portal.' + domain,
    domainTemplate: '*.{region}-{stage}.ui.{domain}',
    bucketTagRole: 'PortalBucket',
    cfTagRole: 'PortalCdn',
  },
];

// ── Template ───────────────────────────────────────────────────────────────
// Merge all site resources with std.foldl — each staticSite() call returns
// a { LogicalId: Resource } object, and + merges them into one flat map.

{
  AWSTemplateFormatVersion: '2010-09-09',
  Description: 'Static sites (' + stage + ') — ' + std.length(sites) + ' CloudFront + S3 distributions',

  Resources: std.foldl(
    function(acc, site) acc + staticSite(site),
    sites,
    {},
  ),

  Outputs: {
    [site.prefix + 'Url']: cfn.output(
      cfn.sub('https://${' + site.prefix + 'Distribution.DomainName}')
    )
    for site in sites
  },
}
