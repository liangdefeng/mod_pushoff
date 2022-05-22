#/bin/sh

## DEVICE_TOKEN="E5B60E5046D13A2A582056A0A489084FA76C68DFDD9891DB97EBFEFCBA5686A6"
TOPIC=$1

DEVICE_TOKEN=$2

APN_PUSH_TYPE=$3

TYPE=$4

STATUS=$5

ROOMID=$6

SENDER=$7

TIME=$8

MSG=$(echo '{"aps":{"alert":{"rootid":"'"${ROOMID}"'","sender":"'"${SENDER}"'","status":"'"${STATUS}"'","type":"'"${TYPE}"'","time":"'"${TIME}"'"}}}')

# APNS_HOST_NAME="api.push.apple.com"
APNS_HOST_NAME="api.sandbox.push.apple.com"

AUTH_KEY_ID="DX7FMWT2FG"

TEAM_ID="RM4Y96X594"

TOKEN_KEY_FILE_NAME="/home/charles/ejabberd-21.12/ssl/APN_AuthKey.p8"

JWT_ISSUE_TIME=$(date +%s)

JWT_HEADER=$(printf '{ "alg": "ES256", "kid": "%s" }' "${AUTH_KEY_ID}" | openssl base64 -e -A | tr -- '+/' '-_' | tr -d =)

JWT_CLAIMS=$(printf '{ "iss": "%s", "iat": %d }' "${TEAM_ID}" "${JWT_ISSUE_TIME}" | openssl base64 -e -A | tr -- '+/' '-_' | tr -d =)

JWT_HEADER_CLAIMS="${JWT_HEADER}.${JWT_CLAIMS}"

JWT_SIGNED_HEADER_CLAIMS=$(printf "${JWT_HEADER_CLAIMS}" | openssl dgst -binary -sha256 -sign "${TOKEN_KEY_FILE_NAME}" | openssl base64 -e -A | tr -- '+/' '-_' | tr -d =)

AUTHENTICATION_TOKEN="${JWT_HEADER}.${JWT_CLAIMS}.${JWT_SIGNED_HEADER_CLAIMS}"

curl -vs \
--header "apns-topic: $TOPIC" \
--header "apns-push-type: $APN_PUSH_TYPE" \
--header 'Content-Type: application/json' \
--header "authorization: bearer $AUTHENTICATION_TOKEN" \
--data "$MSG" \
--http2 \
https://${APNS_HOST_NAME}/3/device/${DEVICE_TOKEN} \
2>&1 | grep -A 10 "< HTTP/2"