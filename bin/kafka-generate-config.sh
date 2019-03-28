#!/bin/bash
# Generates the configuration based on the ConfigMap properties

[ $# -lt 2 ] \
    && echo "ERROR: Missing parameter. ConfigMap mount path and configuration file path are required." \
    && exit 1

# create the testing cert file
unsecureCert=$(mktemp)
cat $KAFKA_CONFIG_DIR/os-certs/* > $unsecureCert

KAFKA_CONFIG_PROPS_PATH=$1
KAFKA_CONFIG_FILE=$2
KAFKA_CERTS_DIR=$KAFKA_CONFIG_DIR/certificates
KAFKA_SERVER_CERT_FILE=$KAFKA_CERTS_DIR/server-cert
KAFKA_BMW_CA_CERTS_FILE=$KAFKA_CERTS_DIR/bmw-ca-certs
KAFKA_TLS_CONFIG_DIR=$KAFKA_CONFIG_DIR/tls

UNSECURE_CA_CERTS_FILE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt

if [ "USE_UNSECURE_TESTING_CERT" = $(cat $KAFKA_SERVER_CERT_FILE) ]
then
	echo "WARNING: An unsecure testing certificate will be configured for the brokers. Provide no certificate or a proper one if this is a production environment."
	KAFKA_SERVER_CERT_FILE=$unsecureCert
	unsecureCertEnabled="true"
fi

[ ! -d $KAFKA_CONFIG_PROPS_PATH ] \
    && echo "ERROR: ConfigMap mount path '$KAFKA_CONFIG_PROPS_PATH' does not exist." \
    && exit 10

echo "Generating Kafka configuration in '$KAFKA_CONFIG_FILE'."

add_property() {
    echo "Adding: $1"
    echo "$1" >> $KAFKA_CONFIG_FILE
    return 0
}

# remove configuration file if it exists already
rm -f $KAFKA_CONFIG_FILE

# write ConfigMap properties to the configuration file
for propFile in $(ls -1U $KAFKA_CONFIG_PROPS_PATH/*)
do
    propName=$(basename $propFile)
    propValue=$(cat $propFile)
    
    ( [ "$propName" == "advertised.host.name" ] \
            || [ "$propName" == "advertised.listeners" ] \
            || [ "$propName" == "advertised.port" ] \
            || [ "$propName" == "broker.id" ] \
            || [ "$propName" == "listeners" ] \
            || [ "$propName" == "log.dir" ] \
            || [ "$propName" == "log.dirs" ] \
            || [ "$propName" == "ssl.keystore.location" ] \
            || [ "$propName" == "ssl.keystore.password" ] \
            || [ "$propName" == "ssl.keystore.type" ] \
            || [ "$propName" == "ssl.truststore.location" ] \
            || [ "$propName" == "ssl.truststore.password" ] \
            || [ "$propName" == "ssl.truststore.type" ] \
            || [ "$propName" == "zookeeper.connect" ] ) \
        && echo "Skipping $propName. Not allowed to specify this in the ConfigMap." \
        && continue
    
    add_property "$propName=$propValue"
done

# configure TLS
if [ -f $KAFKA_SERVER_CERT_FILE ] && [ $(stat -c %s $(readlink -e $KAFKA_SERVER_CERT_FILE)) -gt 0 ]
then
    echo "Server certificate found - configuring TLS."
    mkdir $KAFKA_TLS_CONFIG_DIR
    
    # create keystore
    intermediateKeystore=$(mktemp)
    keystoreFile=$KAFKA_TLS_CONFIG_DIR/keystore.jks
    keystorePassword=$(openssl rand -hex 32)
    echo "Creating keystore for private key."
    ! openssl pkcs12 -export -in $KAFKA_SERVER_CERT_FILE -out $intermediateKeystore -passout pass:intermediate -name broker \
        && echo "ERROR: Failed to create keystore from provided server certificate." \
        && rm -f $intermediateKeystore \
        && exit 20
    ! keytool -importkeystore -srckeystore $intermediateKeystore -srcstoretype pkcs12 -srcstorepass intermediate -alias broker -destkeystore $KAFKA_TLS_CONFIG_DIR/keystore.jks -deststoretype JKS -deststorepass "$keystorePassword" -destkeypass "$keystorePassword" \
        && echo "ERROR: Failed to convert PKCS#12 to JKS keystore." \
        && rm -f $intermediateKeystore \
        && exit 21
    rm -f $intermediateKeystore
    add_property "ssl.keystore.location=$keystoreFile"
    echo "Adding: ssl.keystore.password=[hidden]"
    echo "ssl.keystore.password=$keystorePassword" >> $KAFKA_CONFIG_FILE
    add_property "ssl.keystore.type=JKS"
    
    # create truststore
    truststoreFile=$KAFKA_TLS_CONFIG_DIR/truststore.jks
    truststorePassword=$(openssl rand -hex 32)
    numBmwCaCerts=$(grep 'END CERTIFICATE' $KAFKA_BMW_CA_CERTS_FILE | wc -l)
    echo "Adding $numBmwCaCerts trusted root and intermediate certificates."
    for index in $(seq 0 $((numBmwCaCerts-1)))
    do
        alias="bmw-ca-cert-$index"
        ! cat $KAFKA_BMW_CA_CERTS_FILE | awk "n==$index { print }; /END CERTIFICATE/ { n++ }" | keytool -noprompt -import -trustcacerts -alias $alias -keystore $truststoreFile -storepass $truststorePassword \
            && echo "ERROR: Failed to add trusted certificate [$index]." \
            && exit 22
    done
    add_property "ssl.truststore.location=$truststoreFile"
    echo "Adding: ssl.truststore.password=[hidden]"
    echo "ssl.truststore.password=$truststorePassword" >> $KAFKA_CONFIG_FILE
    add_property "ssl.truststore.type=JKS"
    
    if [ -n $unsecureCertEnabled ]
    then
	    # create truststore for the unsecure testing certificate
	    mkdir $KAFKA_TLS_CONFIG_DIR/unsecure
	    unsecureTrustStoreFile=$KAFKA_TLS_CONFIG_DIR/unsecure/truststore.jks
	    unsecureTruststorePassword="changeit"
	    numUnsecureCaCerts=$(grep 'END CERTIFICATE' $UNSECURE_CA_CERTS_FILE | wc -l)
	    echo "Adding $numUnsecureCaCerts trusted root and intermediate certificates to unsecure truststore for testing purposes."
	    for index in $(seq 0 $((numUnsecureCaCerts-1)))
	    do
	        alias="unsecure-ca-cert-$index"
	        ! cat $UNSECURE_CA_CERTS_FILE | awk "n==$index { print }; /END CERTIFICATE/ { n++ }" | keytool -noprompt -import -trustcacerts -alias $alias -keystore $unsecureTrustStoreFile -storepass $unsecureTruststorePassword \
	            && echo "ERROR: Failed to add trusted certificate [$index]." \
	            && exit 22
	    done
	fi

    # configure service and route for the pod
    echo "Creating OpenShift route for the pod for external access."
    ! java -cp $KAFKA_BIN_DIR/kafka-controller-*.jar net.bmwgroup.connectivity.kafka.controller.KafkaBrokerStartupController \
            "https://${KUBERNETES_SERVICE_HOST}" \
            "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
            "$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)" \
            ${HOSTNAME} \
            9093 \
            ${KAFKA_CONFIG_DIR}/route-hostname \
        && echo "ERROR: Failed to create the OpenShift route." \
        && exit 23
    add_property "advertised.listeners=INTERNAL://$(hostname -f):9092,EXTERNAL://$(cat ${KAFKA_CONFIG_DIR}/route-hostname):443"
	if [ "$ENABLE_ACLS" = "true" ]
	then
		if [ -n "$KAFKA_USER" ]
		then
			echo "Kafka user found and ACLs are enabled - configuring ACLs."
			add_property "super.users=User:$KAFKA_USER"
			add_property "authorizer.class.name=kafka.security.auth.SimpleAclAuthorizer"
		else
			echo "WARNING: No Kafka user found even though ENABLE_ACLS is set to true. ACLs will not be activated"
		fi
	else
		echo "ENABLE_ACLS is not set to true. ACLs will not be activated"
	fi
else
    echo "No server certificate found. TLS and external access will not be activated."
fi

# write standard configuration parameters to the configuration file
add_property "log.dirs=/var/lib/kafka/data"

# cleanup the testing certificate
rm -f $unsecureCert
