#!/usr/bin/env bash

set -e -o pipefail

my_dir="$( cd $(dirname $0) && pwd )"
release_dir="$( cd ${my_dir} && cd ../.. && pwd )"

source ${release_dir}/ci/tasks/utils.sh

: ${bosh_io_bucket_name:?}
: ${bosh_io_bucket_region:?}
: ${image_description:="NO DELETING. A bosh stemcell used to deploy bosh."}
: ${image_region:?}
: ${image_access_key:?}
: ${image_secret_key:?}
: ${image_bucket_name:?}

wget -q -O jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
chmod +x ./jq
cp jq /usr/bin

saved_image_destinations="$(echo $(aliyun ecs DescribeRegions \
    --access-key-id ${image_access_key} \
    --access-key-secret ${image_secret_key} \
    --region ${image_region}
    ) | jq -r '.Regions.Region[].RegionId'
    )"

: ${image_destinations:=$saved_image_destinations}

stemcell_path=${PWD}/input-stemcell/*.tgz
output_path=${PWD}/light-stemcell
success_message=${PWD}/notification/success
failed_message=${PWD}/notification/failed

echo "Checking if light stemcell already exists..."

original_stemcell_name="$(basename ${stemcell_path})"
light_stemcell_name="light-${original_stemcell_name}"

# Write the failed message
echo -e "[bosh-alicloud-light-stemcell-builder Failed]\nBuild the latest ligth stemcell ${light_stemcell_name} failed. Please check it!" > ${failed_message}

bosh_io_light_stemcell_url="https://$bosh_io_bucket_name.oss-$bosh_io_bucket_region.aliyuncs.com/$light_stemcell_name"
set +e
wget --spider "$bosh_io_light_stemcell_url"
if [[ "$?" == "0" ]]; then
  echo "Alibaba Cloud light stemcell '$light_stemcell_name' already exists!"
  echo "You can download here: $bosh_io_light_stemcell_url"
  # Write the failed message
  echo -e "[bosh-alicloud-light-stemcell-builder Failed]\nThe latest ligth stemcell ${light_stemcell_name} already exists in $bosh_io_light_stemcell_url." > ${failed_message}
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

echo -e "Uploading raw image ${stemcell_image_name} to ${image_region} bucket ${image_bucket_name}..."
aliyun oss cp ${stemcell_image} oss://${image_bucket_name}/${stemcell_image_name} -f --access-key-id ${image_access_key} --access-key-secret ${image_secret_key} --region ${image_region}

ImportImageResponse="$(aliyun ecs ImportImage \
    --access-key-id ${image_access_key} \
    --access-key-secret ${image_secret_key} \
    --region ${image_region} \
    --Platform $os_distro \
    --DiskDeviceMapping.1.OSSBucket ${image_bucket_name} \
    --DiskDeviceMapping.1.OSSObject ${stemcell_image_name} \
    --DiskDeviceMapping.1.DiskImageSize $disk_size_gb \
    --DiskDeviceMapping.1.Format $disk_format \
    --Architecture $architecture \
    --ImageName $original_stemcell_name \
    --Description "${image_description}"
    )"

base_image_id="$( echo $ImportImageResponse | jq -r '.ImageId' )"
echo -e "ImportImage in the base region $image_region successfully and the base image id is $base_image_id."

echo -e "Waiting for image $base_image_id is Available..."
timeout=1200
while [ $timeout -gt 0 ]
do
    DescribeImagesResponse="$(aliyun ecs DescribeImages \
            --access-key-id ${image_access_key}  \
            --access-key-secret ${image_secret_key} \
            --region ${image_region} \
            --RegionId ${image_region} \
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

# Remove the raw image
aliyun oss rm oss://${image_bucket_name}/root.img --region ${image_region} --access-key-id ${image_access_key}  --access-key-secret ${image_secret_key}

echo -e "An image $base_image_id has been created in ${image_region} successfully and then start to copy it to otheres regions:\n${image_destinations}."

# Write the success message
echo -e "[bosh-alicloud-light-stemcell-builder In Progress]\nThe following custom images need to be shared with all of Alibaba Cloud Accounts:" > ${success_message}
echo -e "    Region               ImageId" >> ${success_message}

echo "  image_id:" >> ${stemcell_manifest}

for regionId in ${image_destinations[*]}
do
    if [[ $regionId == ${image_region} ]]; then
        image_id=$base_image_id
    else
        CopyImageResponse="$(aliyun ecs CopyImage \
            --access-key-id ${image_access_key}  \
            --access-key-secret ${image_secret_key} \
            --region ${image_region} \
            --RegionId ${image_region} \
            --ImageId $base_image_id \
            --DestinationRegionId $regionId \
            --DestinationImageName $original_stemcell_name \
            --DestinationDescription "${image_description}" \
            --Tag.1.Key CopyFrom \
            --Tag.1.Value $base_image_id
            )"
        image_id="$(echo $CopyImageResponse | jq -r '.ImageId' )"
        echo -e "CopyImage to $regionId and target image ID is $image_id."
    fi
    echo "    $regionId: $image_id" >> ${stemcell_manifest}
    echo "$image_id" >> ${success_message}
done

pushd ${extracted_stemcell_dir}
  > image
  # the bosh cli sees the stemcell as invalid if tar contents have leading ./
  tar -czf ${output_path}/${light_stemcell_name} *
popd
tar -tf ${output_path}/${light_stemcell_name}
echo -e "Finished!"
ls -l ${output_path}