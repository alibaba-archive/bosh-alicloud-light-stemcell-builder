#!/usr/bin/env bash

ami_region=eu-central-1
original_stemcell_name=bosh-alicloud-kvm-250.9-stemcell

os_distro_Ubuntu="Ubuntu"
os_distro_CentOS="CentOS"
os_distro="ubuntu"

os_distro_tmp=$(echo $os_distro_ubuntu | tr 'A-Z' 'a-z')

if [[ $os_distro_tmp == `echo $os_distro_ubuntu | tr 'A-Z' 'a-z'` ]]; then
    os_distro=$os_distro_Ubuntu
elif [[ $os_distro_tmp == `echo $os_distro_CentOS | tr 'A-Z' 'a-z'` ]]; then
    os_distro=$os_distro_CentOS
fi

disk_size_gb=3
if [[ $disk_size_gb -lt 5 ]]; then
    disk_size_gb=5
fi


ImportImageResponse="$(aliyun ecs ImportImage \
    --access-key-id $ALICLOUD_ACCESS_KEY \
    --access-key-secret $ALICLOUD_SECRET_KEY \
    --RegionId $ami_region \
    --Platform $os_distro \
    --DiskDeviceMapping.1.OSSBucket bosh-io-stemcell \
    --DiskDeviceMapping.1.OSSObject root.img \
    --DiskDeviceMapping.1.DiskImageSize $disk_size_gb \
    --ImageName $original_stemcell_name \
    --Description 'NO DELETING. A bosh stemcell used to deploy bosh.'
    )"

echo -e "ImportImage: $ImportImageResponse"
base_image_id="$( echo $ImportImageResponse | jq -c '.ImageId' )"

echo -e "Waitting for image $base_image_id is Available......"
timeout=1200
while [ $timeout -gt 0 ]
do
    DescribeImagesResponse="$(aliyun ecs DescribeImages \
            --access-key-id $ALICLOUD_ACCESS_KEY \
            --access-key-secret $ALICLOUD_SECRET_KEY \
            --RegionId $ami_region \
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

echo -e "A image $base_image_id has been created successfully!"

#echo  $json | jq -c '.Regions.Region[].RegionId'
echo -e "Start to copy the image $base_image_id to other regions."
echo "  image_id:" >> stemcell.MF
for variable in `echo  $( aliyun ecs DescribeRegions --access-key-id $ALICLOUD_ACCESS_KEY --access-key-secret $ALICLOUD_SECRET_KEY ) | jq -r '.Regions.Region[].RegionId'`
do
    if [[ $variable == $ami_region ]]; then
        mage_id=$base_image_id
    else
        CopyImageResponse="$(aliyun ecs CopyImage \
            --access-key-id $ALICLOUD_ACCESS_KEY \
            --access-key-secret $ALICLOUD_SECRET_KEY \
            --RegionId $ami_region \
            --ImageId $base_image_id \
            --DestinationRegionId $variable \
            --DestinationImageName $original_stemcell_name \
            --DestinationDescription 'NO DELETING. Copied from $base_image_id. A bosh stemcell used to deploy bosh.'
            )"
        echo -e "CopyImage to $variable: $CopyImageResponse"
        image_id="$(echo $CopyImageResponse | jq -r '.ImageId' )"
    fi
    echo "    $variable: $image_id" >> stemcell.MF
done


