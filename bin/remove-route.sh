#!/bin/bash
# removes the OpenShift route for the pod

echo "Removing OpenShift route of the pod."

! java -cp $KAFKA_BIN_DIR/kafka-controller-*.jar net.bmwgroup.connectivity.kafka.controller.KafkaBrokerShutdownController \
        "https://${KUBERNETES_SERVICE_HOST}" \
        "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        "$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)" \
        ${HOSTNAME} \
    && echo "ERROR: Failed to remove the OpenShift route." \
    && exit 1

exit 0