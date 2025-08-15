#!/bin/bash
echo "Testing EFS Mount with Fixed Security Groups"
APP_EFS_ID="fs-0c60c5879a0dcecb1"
DATA_EFS_ID="fs-075a2be536c08840c"
AWS_REGION="ca-central-1"

echo "Creating mount points..."
mkdir -p /app /data

echo "Mounting APP EFS..."
mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${APP_EFS_ID}.efs.${AWS_REGION}.amazonaws.com:/ /app

echo "Mounting DATA EFS..."
mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${DATA_EFS_ID}.efs.${AWS_REGION}.amazonaws.com:/ /data

echo "Setting permissions..."
chown apache:apache /app /data
chmod 755 /app /data

echo "Verification:"
df -h | grep efs && echo "SUCCESS: EFS mounted"
ls -la /app && echo "App EFS accessible"
ls -la /data && echo "Data EFS accessible"

echo "EFS mount test complete"
