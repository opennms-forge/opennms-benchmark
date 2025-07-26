#!/bin/bash
OPENNMS_HOST=192.0.2.197
OPENNMS_USER=admin
OPENNMS_PASS=admin
OPENNMS_PORT=8980

# set -x

#
# Setup Demo data with foreign sources, requisitions and a topology
#
echo -n "Create Foreign Sources                             ... "
curl -s -u ${OPENNMS_USER}:${OPENNMS_PASS} \
     -X POST \
     -H "Content-Type: application/xml" \
     -H "Accept: application/xml" \
     -d @snmp-simulation-5k-batch-01-fs.xml \
     http://${OPENNMS_HOST}:${OPENNMS_PORT}/opennms/rest/foreignSources
echo "DONE"

echo -n "Create Requisition                                 ... "
curl -s -u ${OPENNMS_USER}:${OPENNMS_PASS} \
     -X POST \
     -H "Content-Type: application/xml" \
     -H "Accept: application/xml" \
     -d @snmp-simulation-5k-batch-01.xml \
     http://${OPENNMS_HOST}:${OPENNMS_PORT}/opennms/rest/requisitions
echo "DONE"

echo -n "Import requisition for demo environment            ... "
curl -s -u ${OPENNMS_USER}:${OPENNMS_PASS} \
     -X PUT \
     http://${OPENNMS_HOST}:${OPENNMS_PORT}/opennms/rest/requisitions/snmp-simulation-5k-batch-01/import
echo "DONE"
