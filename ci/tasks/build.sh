#!/usr/bin/env bash

set -e -o pipefail

my_dir="$( cd $(dirname $0) && pwd )"
release_dir="$( cd ${my_dir} && cd ../.. && pwd )"

source ${release_dir}/ci/tasks/utils.sh

: ${bosh_io_bucket_name:?}
: ${bosh_io_bucket_region:?}
: ${ami_description:="NO DELETING. A bosh stemcell used to deploy bosh."}
: ${ami_region:?}
: ${ami_access_key:?}
: ${ami_secret_key:?}
: ${ami_bucket_name:?}

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
output_path=${PWD}/light-stemcell
stemcell_metadata=${PWD}/notification/success
# Write the success message
echo -e "[bosh-alicloud-light-stemcell-builder In Progress]\nThe following custom images need to be shared with all of Alibaba Cloud Accounts:" > ${stemcell_metadata}
echo -e "    Region               ImageId" >> ${stemcell_metadata}

echo "Checking if light stemcell already exists..."

original_stemcell_name="$(basename ${stemcell_path})"
light_stemcell_name="light-${original_stemcell_name}"

# Write the failed message
echo -e "[bosh-alicloud-light-stemcell-builder Failed]\nBuild the latest ligth stemcell ${light_stemcell_name} failed. Please check it!" > ${PWD}/notification/failed

bosh_io_light_stemcell_url="https://$bosh_io_bucket_name.oss-$bosh_io_bucket_region.aliyuncs.com/$light_stemcell_name"
set +e
wget --spider "$bosh_io_light_stemcell_url"
if [[ "$?" == "0" ]]; then
  echo "Alibaba Cloud light stemcell '$light_stemcell_name' already exists!"
  echo "You can download here: $bosh_io_light_stemcell_url"
  # Write the failed message
  echo -e "[bosh-alicloud-light-stemcell-builder Failed]\nThe latest ligth stemcell ${light_stemcell_name} already exists in $bosh_io_light_stemcell_url." > ${PWD}/notification/failed
  exit 1
fi
set -e

mb_to_gb() {
  mb="$1"
  echo "$(( (${mb}+1024-1)/1024 ))"
}

echo "Building light stemcell..."

extracted_stemcell_dir=${PWD}/extracted-stemcell
mkdir -p ${extracted_stemcell_dir}
tar -C ${extracted_stemcell_dir} -xzvf ${stemcell_path}
tar -xzvf ${extracted_stemcell_dir}/image

# image format can be raw or stream optimized vmdk
stemcell_image="$(echo ${PWD}/root.*)"
stemcell_image_name="$(basename ${stemcell_image})"
stemcell_manifest=${extracted_stemcell_dir}/stemcell.MF
manifest_contents="$(cat ${stemcell_manifest})"

disk_regex="disk: ([0-9]+)"
disk_format_regex="disk_format: ([a-z]+)"
os_type_regex="os_type: ([a-z]+)"
os_distro_regex="os_distro: ([a-z]+)"
architecture_regex="architecture: ([0-9a-z_]+)"

[[ "${manifest_contents}" =~ ${disk_regex} ]]
disk_size_gb=$(mb_to_gb "${BASH_REMATCH[1]}")
if [[ $disk_size_gb -lt 5 ]]; then
    disk_size_gb=5
fi

[[ "${manifest_contents}" =~ ${disk_format_regex} ]]
disk_format="$( echo ${BASH_REMATCH[1]} | tr 'a-z' 'A-Z' )"

[[ "${manifest_contents}" =~ ${os_type_regex} ]]
os_type="${BASH_REMATCH[1]}"

os_distro_Ubuntu="Ubuntu"
os_distro_CentOS="CentOS"
[[ "${manifest_contents}" =~ ${os_distro_regex} ]]
os_distro="${BASH_REMATCH[1]}"
if [[ `echo $os_distro | tr 'A-Z' 'a-z'` == `echo $os_distro_Ubuntu | tr 'A-Z' 'a-z'` ]]; then
    os_distro=$os_distro_Ubuntu
elif [[ `echo $os_distro | tr 'A-Z' 'a-z'` == `echo $os_distro_CentOS | tr 'A-Z' 'a-z'` ]]; then
    os_distro=$os_distro_CentOS
fi

[[ "${manifest_contents}" =~ ${architecture_regex} ]]
architecture="${BASH_REMATCH[1]}"

#################### clear last data #####################
#echo "  image_id:" >> ${stemcell_manifest}
#for region_tmp in ${ami_destinations}
#do
#    echo -e "Describing image in $region_tmp..."
#    delete_image_id="$( echo $(aliyun ecs DescribeImages \
#            --access-key-id ${ami_access_key}  \
#            --access-key-secret ${ami_secret_key} \
#            --region ${region_tmp} \
#            --RegionId ${region_tmp} \
#            --ImageName ${original_stemcell_name} \
#            --Status Waiting,Creating,Available,UnAvailable,CreateFailed
#            ) | jq -r '.Images.Image[0].ImageId'
#            )"
##    if [[ $delete_image_id == "null" || $delete_image_id == "" ]]; then
##        continue
##    fi
#    echo "    $region_tmp: $delete_image_id" >> ${stemcell_manifest}
#    echo "$region_tmp:  $delete_image_id" >> ${stemcell_metadata}
##    echo -e "Deleting image $delete_image_id in $region_tmp..."
##    echo "$(aliyun ecs DeleteImage \
##        --access-key-id ${ami_access_key}  \
##        --access-key-secret ${ami_secret_key} \
##        --region ${region_tmp} \
##        --RegionId ${region_tmp} \
##        --ImageId $delete_image_id \
##        --Force true
##        )"
#done
#
#echo "-------------- manifest\n"
#echo $(cat ${stemcell_manifest})
#
##echo -e "Deleting raw image ${stemcell_image_name}..."
##aliyun oss rm oss://${ami_bucket_name}/ -r -f --region ${ami_region} --access-key-id ${ami_access_key}  --access-key-secret ${ami_secret_key}
##echo -e "Deleting bucket ${ami_bucket_name}..."
##aliyun oss rm oss://${ami_bucket_name} -b -f --region ${ami_region} --access-key-id ${ami_access_key}  --access-key-secret ${ami_secret_key}
########################################################

echo -e "Uploading raw image ${stemcell_image_name} to ${ami_region} bucket ${ami_bucket_name}..."

aliyun oss mb oss://${ami_bucket_name} --acl private --access-key-id ${ami_access_key} --access-key-secret ${ami_secret_key} --region ${ami_region}
aliyun oss cp -f ${stemcell_image} oss://${ami_bucket_name}/${stemcell_image_name} --access-key-id ${ami_access_key} --access-key-secret ${ami_secret_key} --region ${ami_region}

ImportImageResponse="$(aliyun ecs ImportImage \
    --access-key-id ${ami_access_key} \
    --access-key-secret ${ami_secret_key} \
    --region ${ami_region} \
    --Platform $os_distro \
    --DiskDeviceMapping.1.OSSBucket ${ami_bucket_name} \
    --DiskDeviceMapping.1.OSSObject ${stemcell_image_name} \
    --DiskDeviceMapping.1.DiskImageSize $disk_size_gb \
    --DiskDeviceMapping.1.Format $disk_format \
    --Architecture $architecture \
    --ImageName $original_stemcell_name \
    --Description ${ami_description}
    )"

echo -e "ImportImage: $ImportImageResponse"
base_image_id="$( echo $ImportImageResponse | jq -r '.ImageId' )"

echo -e "Waiting for image $base_image_id is Available..."
timeout=600
while [ $timeout -gt 0 ]
do
    DescribeImagesResponse="$(aliyun ecs DescribeImages \
            --access-key-id ${ami_access_key}  \
            --access-key-secret ${ami_secret_key} \
            --region ${ami_region} \
            --RegionId ${ami_region} \
            --ImageId $base_image_id \
            --Status Waiting,Creating,Available,UnAvailable,CreateFailed
            )"
    if [[ `echo $DescribeImagesResponse | jq -r '.Images.Image[0].Status'` != "Available" ]]; then
        sleep 5
        timeout=$((${timeout}-5))
    else
        break
    fi
done

aliyun oss rm oss://${ami_bucket_name}/ -r -f --region ${ami_region} --access-key-id ${ami_access_key}  --access-key-secret ${ami_secret_key}
aliyun oss rm oss://${ami_bucket_name} -b -f --region ${ami_region} --access-key-id ${ami_access_key}  --access-key-secret ${ami_secret_key}

echo -e "An image $base_image_id has been created in ${ami_region} successfully and then start to copy it to otheres regions:\n${ami_destinations}."

echo "  image_id:" >> ${stemcell_manifest}

for regionId in ${ami_destinations}
do
    if [[ $regionId == ${ami_region} ]]; then
        image_id=$base_image_id
    else
        CopyImageResponse="$(aliyun ecs CopyImage \
            --access-key-id ${ami_access_key}  \
            --access-key-secret ${ami_secret_key} \
            --region ${ami_region} \
            --RegionId ${ami_region} \
            --ImageId $base_image_id \
            --DestinationRegionId $regionId \
            --DestinationImageName $original_stemcell_name \
            --DestinationDescription ${ami_description} \
            --Tag.1.Key CopyFrom \
            --Tag.1.Value $base_image_id
            )"
        echo -e "CopyImage to $regionId: $CopyImageResponse"
        image_id="$(echo $CopyImageResponse | jq -r '.ImageId' )"
    fi
    echo "    $regionId: $image_id" >> ${stemcell_manifest}
done

pushd ${extracted_stemcell_dir}
  > image
  # the bosh cli sees the stemcell as invalid if tar contents have leading ./
  tar -czf ${output_path}/${light_stemcell_name} *
popd
tar -tf ${output_path}/${light_stemcell_name}
echo -e "Finished!"
ls -l ${output_path}