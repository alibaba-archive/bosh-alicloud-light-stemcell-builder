#!/usr/bin/env bash

set -e -o pipefail

my_dir="$( cd $(dirname $0) && pwd )"
release_dir="$( cd ${my_dir} && cd ../.. && pwd )"

source ${release_dir}/ci/tasks/utils.sh

: ${ami_access_key:?}
: ${ami_secret_key:?}
: ${ami_region:?}

wget -q -O jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
chmod +x ./jq
cp jq /usr/bin

saved_ami_destinations="$(echo $(aliyun ecs DescribeRegions \
    --access-key-id ${ami_access_key} \
    --access-key-secret ${ami_secret_key} \
    --region ${ami_region}
    ) | jq -r '.Regions.Region[].RegionId'
    )"

: ${ami_destinations:=$saved_ami_destinations}

stemcell_path=${PWD}/input-stemcell/*.tgz
original_stemcell_name="$(basename ${stemcell_path})"

echo -e "Checking image ${original_stemcell_name} is ready..."
success=true
while [[ ${success} = false ]]
do
    for regionId in ${ami_destinations}
    do
        DescribeImagesResponse="$(aliyun ecs DescribeImages \
                --access-key-id ${ami_access_key}  \
                --access-key-secret ${ami_secret_key} \
                --region ${regionId} \
                --RegionId ${regionId} \
                --ImageName ${original_stemcell_name}
                )"
        if [[ `echo ${DescribeImagesResponse} | jq -r '.Images.Image[0].ImageId'` = "" ]]; then
            success=false
            echo -e "Cannot find the stemcell ${original_stemcell_name} in the region ${regionId}. Continue..."
            break
            timeout=$((${timeout}-5))
        else
            success=true
        fi
    done
done

# Write the success message
echo -e "Publish the latest light stemcell light-${original_stemcell_name} success." > ${PWD}/notification/success

# Write the failed message
echo -e "Publish the latest light stemcell light-${original_stemcell_name} failed. Please check!" > ${PWD}/notification/failed
