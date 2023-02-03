#!/bin/bash

REGION1=us-east-2
REGION2=us-west-2

function wait_for_stack_to_complete() 
{           
   stackname=${1}
   region=${2}
   while [[ true ]]; do
     status=$(aws cloudformation describe-stacks --region ${region} --query "Stacks[?(StackName == '${stackname}')].StackStatus" --output text)
     if [[ "${status}" == "CREATE_COMPLETE" ]]; then
        echo "Stack ${stackname} on region ${region} completed (${status})"
        return
     fi
     sleep 60
   done
}  

#delete global accelerator
accel=$(aws globalaccelerator list-accelerators --region us-west-2 --query 'Accelerators[?(Name == `eksgdb`)].AcceleratorArn' --output text)
lsnrarn=$(aws globalaccelerator list-listeners --accelerator-arn  $accel --region us-west-2 --query 'Listeners[].ListenerArn' --output text)
aws globalaccelerator  update-accelerator --accelerator-arn $accel --no-enabled --region us-west-2
status=$(aws globalaccelerator list-accelerators --region us-west-2 --query 'Accelerators[?(Name == `eksgdb`)].Status' --output text)
echo $status
while [[ "${status}" == "IN_PROGRESS" ]]; do
   echo "Global Accelerator deployment status ${status}"
   sleep 60
   status=$(aws globalaccelerator list-accelerators --region us-west-2 --query 'Accelerators[?(Name == `eksgdb`)].Status' --output text)
done

for grparn in `aws globalaccelerator list-endpoint-groups --listener-arn $lsnrarn --region us-west-2 --query 'EndpointGroups[].EndpointGroupArn' --output text`
do
   aws globalaccelerator delete-endpoint-group --endpoint-group-arn $grparn --region us-west-2
done

aws globalaccelerator  delete-listener --listener-arn $lsnrarn --region us-west-2
aws globalaccelerator  delete-accelerator --accelerator-arn $accel --region us-west-2

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

kubectl delete ingress,services,deployments,statefulsets -n retailapp --all
kubectl delete ns retailapp --cascade=true

eksctl delete iamserviceaccount --name aws-load-balancer-controller --cluster eksclu --namespace kube-system --region $REGION1
eksctl delete iamserviceaccount --name aws-load-balancer-controller --cluster eksclu --namespace kube-system --region $REGION2
eksctl delete cluster --name eksclu -r ${REGION1} --force -w
eksctl delete cluster --name eksclu -r ${REGION2} --force -w

aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/k8s-asg-policy

VPCID1=$(aws cloudformation describe-stacks --stack-name EKSGDB1 --region ${REGION1} --query 'Stacks[].Outputs[?(OutputKey == `VPC`)][].{OutputValue:OutputValue}' --output text)
CIDR1=$(aws ec2 describe-vpcs --vpc-ids "${VPCID1}" --region ${REGION1} --query 'Vpcs[].CidrBlock' --output text)
VPCID2=$(aws cloudformation describe-stacks --stack-name EKSGDB1 --region ${REGION2} --query 'Stacks[].Outputs[?(OutputKey == `VPC`)][].{OutputValue:OutputValue}' --output text)
CIDR2=$(aws ec2 describe-vpcs --vpc-ids "${VPCID2}" --region ${REGION2} --query 'Vpcs[].CidrBlock' --output text)

VPCPEERID=$(aws ec2 describe-vpc-peering-connections --region ${REGION1} --query "VpcPeeringConnections[?(RequesterVpcInfo.VpcId == '${VPCID1}')].VpcPeeringConnectionId" --output text)

aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id ${VPCPEERID} --region ${REGION1}
aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id ${VPCPEERID} --region ${REGION2}

# delete ECR Repos
for REGION in $REGION1 $REGION2
do
aws ecr delete-repository  --repository-name retailapp/kart --force --region $REGION
aws ecr delete-repository  --repository-name retailapp/order --force --region $REGION
aws ecr delete-repository  --repository-name retailapp/pgbouncer --force --region $REGION
aws ecr delete-repository  --repository-name retailapp/product --force --region $REGION
aws ecr delete-repository  --repository-name retailapp/user --force --region $REGION
aws ecr delete-repository  --repository-name retailapp/webapp --force --region $REGION
done


FAILARN=$(aws rds describe-global-clusters --query 'GlobalClusters[?(GlobalClusterIdentifier == `agdbtest`)].GlobalClusterMembers[]' | jq '.[] | select(.IsWriter == false) | .DBClusterArn'| sed -e 's/"//g')
PRIMARN=$(aws rds describe-global-clusters --query 'GlobalClusters[?(GlobalClusterIdentifier == `agdbtest`)].GlobalClusterMembers[]' | jq '.[] | select(.IsWriter == true) | .DBClusterArn'| sed -e 's/"//g')
PRIMREGION=`echo $PRIMARN | awk -F: '{print $4}'`
GLCLUIDE=agdbtest

if [[ "${PRIMREGION}" == "${REGION2}" ]]; then
   aws rds failover-global-cluster \
     --region $PRIMREGION \
     --global-cluster-identifier agdbtest \
     --target-db-cluster-identifier ${FAILARN}
fi

sleep 300

aws cloudformation delete-stack --stack-name EKSGDB2 --region ${REGION2}
wait_for_stack_to_complete "EKSGDB2" "${REGION2}"

aws lambda delete-function --function-name AuroraGDBPgbouncerUpdate
aws events remove-targets --rule AuroraGDBPgbouncerUpdate --ids "1"
aws events delete-rule --name AuroraGDBPgbouncerUpdate

for role in `aws iam list-roles --query 'Roles[?starts_with(RoleName, \`auroragdbeks-ACKGrantsRole\`) == \`true\`].RoleName' --region $REGION1 --output text`
do
 aws iam delete-role --role-name $role
done
for role in `aws iam list-roles --query 'Roles[?starts_with(RoleName, \`auroragdbeks-EKSIAMRole\`) == \`true\`].RoleName' --region $REGION1 --output text`
do
 aws iam delete-role --role-name $role
done
for role in `aws iam list-roles --query 'Roles[?starts_with(RoleName, \`auroragdbeks-WorkerNodesRole\`) == \`true\`].RoleName' --region $REGION1 --output text`
do
 aws iam delete-role --role-name $role
done

aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerAdditionalIAMPolicy
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy
aws iam detach-role-policy --role-name aurorapgbouncerlambda --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role-policy --role-name aurorapgbouncerlambda --policy-name lambda_rds_policy
aws iam delete-role --role-name aurorapgbouncerlambda

for role in `aws iam list-roles --query 'Roles[?starts_with(RoleName, \`EKSGDB1-C9Role-\`) == \`true\`].RoleName' --region $REGION1 --output text`
do
 aws iam delete-role --role-name $role
done

aws cloudformation delete-stack --stack-name auroragdbeks --region ${REGION2}
wait_for_stack_to_complete "auroragdbeks" "${REGION2}"

aws cloudformation delete-stack --stack-name auroragdbeks --region ${REGION1}
wait_for_stack_to_complete "auroragdbeks" "${REGION1}"

for s3buck in `aws s3api list-buckets --query 'Buckets[?starts_with(Name, \`eksgdb1-c9outputbucket\`)].Name' --output text`
do
  aws s3 rm s3://$s3buck/ --recursive
  aws s3api delete-bucket --bucket $s3buck
done

aws cloudformation delete-stack --stack-name EKSGDB1 --region ${REGION2}
wait_for_stack_to_complete "EKSGDB1" "${REGION2}"
aws cloudformation delete-stack --stack-name EKSGDB1 --region ${REGION1}
wait_for_stack_to_complete "EKSGDB1" "${REGION1}"