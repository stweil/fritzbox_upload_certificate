#!/bin/bash

# Copyright (C) 2020 Franz Schwartau
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# default parameters from environment
baseurl="${FRITZBOX_BASEURL:-}"
certpath="${FRITZBOX_CERTPATH:-}"
password="${FRITZBOX_PASSWORD:-}"
username="${FRITZBOX_USERNAME:-}"

CURL_CMD=curl
ICONV_CMD=iconv

SUCCESS_MESSAGES="^(Das SSL-Zertifikat wurde erfolgreich importiert|Import of the SSL certificate was successful|El certificado SSL se ha importado correctamente|Le certificat SSL a été importé|Il certificato SSL è stato importato|Import certyfikatu SSL został pomyślnie zakończony)\.$"

function usage {
  echo "Usage: $0 [-b baseurl] [-u username] [-p password] [-c certpath]" >&2
  exit 64
}

function error {
  local msg=$1

  [ "${msg}" ] && echo "${msg}" >&2
  exit 1
}

md5cmd=

for cmd in md5 md5sum; do
  if which ${cmd} > /dev/null 2>&1; then
    md5cmd=${cmd}
    break
  fi
done

if [ -z "${md5cmd}" ]; then
  error "Missing command for calculating MD5 hash"
fi

exit=0

for cmd in ${CURL_CMD} ${ICONV_CMD}; do
  if ! which ${cmd} > /dev/null 2>&1; then
    echo "Please install ${cmd}" >&2
    exit=1
  fi
done

[ ${exit} -ne 0 ] && exit ${exit}

while getopts ":b:c:p:u:h" opt; do
  case ${opt} in
    b)
      baseurl=$OPTARG
      ;;
    c)
      certpath=$OPTARG
      ;;
    p)
      password=$OPTARG
      ;;
    u)
      username=$OPTARG
      ;;
    h)
      usage
      ;;
    \?)
      echo "Invalid option: $OPTARG" >&2
      echo >&2
      usage
      ;;
    :)
      echo "Invalid option: $OPTARG requires an argument" >&2
      echo >&2
      usage
      ;;
  esac
done

shift $((OPTIND -1))

exit=0

for var in baseurl certpath username password; do
  if [ -z "${!var}" ]; then
    echo "Please set ${var}" >&2
    exit=1
  fi
done

[ ${exit} -ne 0 ] && exit ${exit}

if [ ! -r "${certpath}/fullchain.pem" -o ! -r "${certpath}/privkey.pem" ]; then
  error "Certpath ${certpath} must contain fullchain.pem and privkey.pem"
fi

request_file="$(mktemp -t XXXXXX)"
trap "rm -f ${request_file}" EXIT

# login to the box and get a valid SID
challenge="$(${CURL_CMD} -sS ${baseurl}/login_sid.lua | sed -ne 's/^.*<Challenge>\([0-9a-f][0-9a-f]*\)<\/Challenge>.*$/\1/p')"
if [ -z "${challenge}" ]; then
  error "Invalid challenge received."
fi

md5hash="$(echo -n ${challenge}-${password} | ${ICONV_CMD} -f ASCII -t UTF-16LE | ${md5cmd} | awk '{print $1}')"

sid="$(${CURL_CMD} -sS "${baseurl}/login_sid.lua?username=${username}&response=${challenge}-${md5hash}" | sed -ne 's/^.*<SID>\([0-9a-f][0-9a-f]*\)<\/SID>.*$/\1/p')"
if [ -z "${sid}" -o "${sid}" = "0000000000000000" ]; then
  error "Login failed."
fi

certbundle=$(cat "${certpath}/fullchain.pem" "${certpath}/privkey.pem" | grep -v '^$')

# generate our upload request
boundary="---------------------------$(date +%Y%m%d%H%M%S)"

cat <<EOD >> ${request_file}
--${boundary}
Content-Disposition: form-data; name="sid"

${sid}
--${boundary}
Content-Disposition: form-data; name="BoxCertImportFile"; filename="BoxCert.pem"
Content-Type: application/octet-stream

${certbundle}
--${boundary}--
EOD

# upload the certificate to the box
${CURL_CMD} -sS -X POST ${baseurl}/cgi-bin/firmwarecfg -H "Content-type: multipart/form-data boundary=${boundary}" --data-binary "@${request_file}" | grep -qE "${SUCCESS_MESSAGES}"
if [ $? -ne 0 ]; then
  error "Could not import certificate."
fi
