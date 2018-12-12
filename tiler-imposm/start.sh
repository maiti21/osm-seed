#!/bin/bash
set -e
mkdir -p /tmp
stateFile="state.txt"
PBFFile="osm.pbf"
limitFile="limitFile.geojson"
flag=true

# directories to keep the imposm's cache for updating the db
cachedir="/mnt/data/cachedir"
mkdir -p $cachedir
diffdir="/mnt/data/diff"
mkdir -p $diffdir

# Create config file to set variable  for imposm
echo "{" > config.json
echo "\"cachedir\": \"$cachedir\","  >> config.json
echo "\"diffdir\": \"$diffdir\","  >> config.json
echo "\"connection\": \"postgis://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST/$POSTGRES_DB\"," >> config.json
echo "\"mapping\": \"imposm3.json\""  >> config.json
echo "}" >> config.json

# Creating a gcloud-service-key to authenticate the gcloud
if [ $CLOUDPROVIDER == "gcp" ]; then
    echo $GCP_SERVICE_KEY | base64 --decode --ignore-garbage > gcloud-service-key.json
    /root/google-cloud-sdk/bin/gcloud --quiet components update
    /root/google-cloud-sdk/bin/gcloud auth activate-service-account --key-file gcloud-service-key.json
    /root/google-cloud-sdk/bin/gcloud config set project $GCP_PROJECT
fi

function getData () {
    # Import from pubic url, ussualy it come from osm
    if [ $TILER_IMPORT_FROM == "osm" ]; then 
        wget $TILER_IMPORT_PBF_URL -O $PBFFile
    fi

    if [ $TILER_IMPORT_FROM == "osmseed" ]; then 
        if [ $CLOUDPROVIDER == "aws" ]; then 
            # Get the state.txt file from S3
            aws s3 cp $S3_OSM_PATH/planet/full-history/$stateFile .
            PBFCloudPath=$(tail -n +1 $stateFile)
            aws s3 cp $PBFCloudPath $PBFFile
        fi
        # Google storage
        if [ $CLOUDPROVIDER == "gcp" ]; then 
            # Get the state.txt file from GS
            gsutil cp $GS_OSM_PATH/planet/full-history/$stateFile .
            PBFCloudPath=$(tail -n +1 $stateFile)
            gsutil cp $PBFCloudPath $PBFFile
        fi
    fi
}

function updateData(){
    if [ -z "$TILER_IMPORT_LIMIT" ]; then
        wget $TILER_IMPORT_LIMIT -O $limitFile
        imposm run -config config.json -cachedir $cachedir -diffdir $diffdir -limitto $limitFile &     
        while true
        do 
            echo "Updating...$(date +%F_%H-%M-%S)"
            sleep 1m
        done
    else
        imposm run -config config.json -cachedir $cachedir -diffdir $diffdir &     
        while true
        do 
            echo "Updating...$(date +%F_%H-%M-%S)"
            sleep 1m
        done
    fi
}

function importData () {
    echo "Execute the missing functions"
    psql "postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST/$POSTGRES_DB" -a -f postgis_helpers.sql
    psql "postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST/$POSTGRES_DB" -a -f postgis_index.sql
    echo "Import Natural Earth"
    ./scripts/natural_earth.sh
    echo "Impor OMS Land"
    ./scripts/osm_land.sh
    echo "Import PBF file"

    if [ -z "$TILER_IMPORT_LIMIT" ]; then
        wget $TILER_IMPORT_LIMIT -O $limitFile
        imposm import \
        -config config.json \
        -read $PBFFile \
        -write \
        -diff -cachedir $cachedir -diffdir $diffdir \
        -limitto $limitFile
    else
        imposm import \
        -config config.json \
        -read $PBFFile \
        -write \
        -diff -cachedir $cachedir -diffdir $diffdir
    fi

    imposm import \
    -config config.json \
    -deployproduction
    # -diff -cachedir $cachedir -diffdir $diffdir
    # Update the DB
    updateData
}

echo "Connecting... to postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST/$POSTGRES_DB"

while "$flag" = true; do
    pg_isready -h $POSTGRES_HOST -p 5432 >/dev/null 2>&2 || continue
        # Change flag to false to stop ping the DB
        flag=false
        hasData=$(psql "postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST/$POSTGRES_DB" \
        -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" | sed -n 3p | sed 's/ //g')
        # After import there are more than 70 tables
        if [ $hasData  \> 70 ]; then
            echo "Update the DB with osm data"
            updateData
        else
            echo "Import PBF data to DB"
            getData
            if [ -f $PBFFile ]; then
                echo "Start importing the data"
                importData
            fi
        fi
done