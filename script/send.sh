#/bin/sh

#### Paramters
TOPIC=$1
DEVICE_TOKEN=$2
APN_PUSH_TYPE=$3
TITLE=$4
BODY=$5

#######################

if [ -z "$5" ]
then
  MSG=$(echo '{"aps":{"alert":{"title":"'"${TITLE}"'"},"sound":"bingbong.aiff"}}')
else

  MSG=$(echo '{"aps":{"alert":{"title":"'"${TITLE}"'","body":"'"${BODY}"'"},"sound":"bingbong.aiff"}}')
fi

# Production
# APNS_HOST_NAME="api.push.apple.com"

# sandbox
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