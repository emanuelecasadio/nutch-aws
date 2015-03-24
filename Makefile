# Makefile for Running Nutch on AWS EMR
#
#
# run
# % make
# to get the list of options.
#
# based on Karan Bathia's Makefile from: https://github.com/lila/SimpleEMR/blob/master/Makefile

#
# commands setup (ADJUST THESE IF NEEDED)
#

ACCESS_KEY_ID = 
SECRET_ACCESS_KEY = 

# First of all, the Key Pair must be recognized by EC2!
# Check it on the "AWS Web Console -> EC2 -> Network & Security -> Key Pairs" section
EC2_KEY_NAME = 

# Location of the PRIVATE key of the key pair specified above
KEYPATH = 

# The VPC subnet where you want your EC2 instances to be created
SUBNET_ID = 

AWS_REGION = 
S3_BUCKET = 

# Number of the secondary machines (there is always a master)
CLUSTERSIZE = 3

DEPTH = 5
TOPN = 5
MASTER_INSTANCE_TYPE = m1.medium
SLAVE_INSTANCE_TYPE = m1.medium
#  
AWS = aws
ANT = ant
#
ifeq ($(origin AWS_CONFIG_FILE), undefined)
	export AWS_CONFIG_FILE:=aws.conf
endif



#
# variables used internally in makefile
#
seedfiles := $(wildcard urls/*)

AWS_CONF = '[default]\naws_access_key_id=${ACCESS_KEY_ID}\naws_secret_access_key=${SECRET_ACCESS_KEY}\nregion=${AWS_REGION}'

NUTCH-SITE-CONF= "<?xml version=\"1.0\"?> \
<?xml-stylesheet type=\"text/xsl\" href=\"configuration.xsl\"?> \
<configuration> \
<property> \
  <name>http.agent.name</name> \
  <value>efcrawler</value> \
  <description></description> \
</property> \
<property> \
  <name>http.robots.agents</name> \
  <value>mycrawler,*</value> \
  <description></description> \
</property> \
</configuration>"

INSTANCE_GROUPS = '[  \
  {  \
    "InstanceCount": 1,  \
    "Name": "NutchCrawlerMaster",  \
    "InstanceGroupType": "MASTER",  \
    "InstanceType": "m1.medium"  \
  },  \
  {  \
    "InstanceCount": 1,  \
    "Name": "NutchCrawlerCore",  \
    "InstanceGroupType": "CORE",  \
    "InstanceType": "m1.medium"  \
  }  \
]'

EC2_ATTRIBUTES = '{  \
  "KeyName": "${EC2_KEY_NAME}",  \
  "SubnetId": "${SUBNET_ID}"  \
}'

STEPS = '[  \
  {  \
    "Name": "nutch-crawl",  \
    "Args": ["s3://${S3_BUCKET}/urls", "-dir", "crawl", "-depth", "${DEPTH}", "-topN", "${TOPN}"], \
    "Jar": "s3://${S3_BUCKET}/lib/apache-nutch-1.6.job.jar", \
    "ActionOnFailure": "TERMINATE_CLUSTER",  \
    "MainClass": "org.apache.nutch.crawl.Crawl", \
    "Type": "CUSTOM_JAR"  \
  },  \
  {  \
    "Name": "nutch-crawl",  \
    "Args": ["crawl/mergedsegments", "-dir", "crawl/segments"], \
    "Jar": "s3://${S3_BUCKET}/lib/apache-nutch-1.6.job.jar", \
    "ActionOnFailure": "TERMINATE_CLUSTER",  \
    "MainClass": "org.apache.nutch.segment.SegmentMerger", \
    "Type": "CUSTOM_JAR"  \
  },  \
  {  \
    "Name": "crawlData2S3",  \
    "Args": ["--src","hdfs:///user/hadoop/crawl/crawldb","--dest","s3://${S3_BUCKET}/crawl/crawldb","--srcPattern",".*","--outputCodec","snappy"], \
    "Jar": "s3://elasticmapreduce/libs/s3distcp/role/s3distcp.jar", \
    "ActionOnFailure": "TERMINATE_CLUSTER",  \
    "Type": "CUSTOM_JAR"  \
  },  \
  {  \
    "Name": "crawlData2S3",  \
    "Args": ["--src","hdfs:///user/hadoop/crawl/linkdb","--dest","s3://${S3_BUCKET}/crawl/linkdb","--srcPattern",".*","--outputCodec","snappy"], \
    "Jar": "s3://elasticmapreduce/libs/s3distcp/role/s3distcp.jar", \
    "ActionOnFailure": "TERMINATE_CLUSTER",  \
    "Type": "CUSTOM_JAR"  \
  },  \
  {  \
    "Name": "crawlData2S3",  \
    "Args": ["--src","hdfs:///user/hadoop/crawl/mergedsegments","--dest","s3://${S3_BUCKET}/crawl/segments","--srcPattern",".*","--outputCodec","snappy"], \
    "Jar": "s3://elasticmapreduce/libs/s3distcp/role/s3distcp.jar", \
    "ActionOnFailure": "TERMINATE_CLUSTER",  \
    "Type": "CUSTOM_JAR"  \
  }  \
]'

#
# make targets
#
.PHONY: help
help:
	@echo "help for Makefile for running Nutch on AWS EMR "
	@echo "make create - create an EMR Cluster with default settings "
	@echo "make destroy - clean up everything (terminate cluster )"
	@echo
	@echo "make ssh - log into master node of cluster"


#
# top level target to tear down cluster and cleanup everything
#
.PHONY: destroy
destroy:
	-${AWS} emr terminate-clusters `cat ./clusterid`
	rm ./clusterid

#
# top level target to create a new cluster of c1.mediums
#
.PHONY: create
create: 
	@ if [ -a ./clusterid ]; then echo "clusterid exists! exiting"; exit 1; fi
	@ echo creating EMR cluster
	${AWS} --output text  emr  create-cluster --ami-version 3.5.0 --instance-groups ${INSTANCE_GROUPS} --no-auto-terminate --name NutchCrawler --ec2-attributes ${EC2_ATTRIBUTES} --steps ${STEPS} --log-uri "s3://${S3_BUCKET}/logs" | head -1 > ./clusterid

#
# load the nutch jar and seed files to s3
#

.PHONY: bootstrap
bootstrap: | aws.conf apache-nutch-1.6-src.zip apache-nutch-1.6/build/apache-nutch-1.6.job  creates3bucket seedfiles2s3 
	${AWS} s3api put-object --bucket ${S3_BUCKET} --key lib/apache-nutch-1.6.job.jar --body apache-nutch-1.6/build/apache-nutch-1.6.job

#
#  create se bucket
#
.PHONY: creates3bucket
creates3bucket:
	${AWS} s3api create-bucket --bucket ${S3_BUCKET}

#
#  copy from url foder to s3
#
.PHONY: seedfiles2s3 $(seedfiles)
seedfiles2s3: $(seedfiles) 

$(seedfiles):
	${AWS} s3api put-object --bucket ${S3_BUCKET} --key $@ --body $@

#
#  download and unzip nutch source code
#
apache-nutch-1.6-src.zip:
	curl -O http://archive.apache.org/dist/nutch/1.6/apache-nutch-1.6-src.zip
	unzip apache-nutch-1.6-src.zip
	echo ${NUTCH-SITE-CONF} > apache-nutch-1.6/conf/nutch-site.xml

#
#  build nutch job jar
#
apache-nutch-1.6/build/apache-nutch-1.6.job: $(wildcard apache-nutch-1.6/conf/*)
	${ANT} -f apache-nutch-1.6/build.xml

#
# ssh: quick wrapper to ssh into the master node of the cluster
#
ssh: aws.conf
	h=`${AWS} emr describe-cluster --cluster-id \`cat ./clusterid\` | grep "MasterPublicDnsName" | cut -d "\"" -f 4`; echo "h=$$h"; if [ -z "$$h" ]; then echo "master not provisioned"; exit 1; fi
	h=`${AWS} emr describe-cluster --cluster-id \`cat ./clusterid\` | grep "MasterPublicDnsName" | cut -d "\"" -f 4`; ssh -L 9100:localhost:9100 -i ${KEYPATH} "hadoop@$$h"

#
# created the config file for aws-cli
#
aws.conf:
	@echo -e ${AWS_CONF} > aws.conf

s3.list: aws.conf
	aws --output text s3api list-buckets




