#!/bin/bash

# This is a modification of gitlab-gc.sh script created by Peter Bábics (pbabics/gitlab-gc.sh)

# Improvements
#   - Searching in all BASE_PATH, not fixing the search to a depth of 2
#   - Directories without valid tags or revisions directories won't be processed (to avoid unexpected issues)
#   - Logging in case there's nothing to delete
#   - running registry-garbage-collect only when something has been deleted

# Adequações - Paulo Rogério
#   - Excluir as todas as ultimas tags, mantendo apenas as KEEP_LAST_IMAGES.
#   - Tags no formato " latest | stable | x.x.x | hash" são excluídas mantendo sempre a quantidade definida em KEEP_LAST_IMAGES.  

# crontab example
# Run everynight the script, keeping 5 old revisions and running registry-garbage-collector at the end. All stdout logs sent to a file rotated every month
# 00 23 * * * { echo "STARTING EXEC $(date)"; /root/scripts/gitlab-registry-gc.sh -k 5 -r; } >> /root/scripts/logs/stdout_gitlab-registry-gc.$(date "+\%Y\%m").log 2>&1

BASE_PATH=/var/opt/gitlab/gitlab-rails/shared/registry/docker/registry/v2/repositories

DRY_RUN=0
KEEP_LAST_IMAGES=10
RUN_GARBAGE_COLLECTOR=0
GITLAB_CTL_COMMAND=`which gitlab-ctl`


if [ ! -x "${GITLAB_CTL_COMMAND}" ]; then
    echo "Missing gitlab-ctl command"
    exit 1
fi


while (( "$#" )); do
    case "$1" in

        "-b" | "--base-path")
            BASE_PATH=$2
            shift
            ;;

        "-r" | "--run-gc")
            RUN_GARBAGE_COLLECTOR=1
            ;;

        "-d"|"--dry-run")
            DRY_RUN=1
            ;;

        "-k"|"--keep")
            if ! ( echo $2 | grep -q '^[0-9]\+$') || [ $2 -eq 0 ]; then
                echo "Invalid value for keep last images '$2'"
                exit 1
            fi
            KEEP_LAST_IMAGES=$2
            shift
            ;;

        "-h"|"--help")
            echo "Usage: ${0} [options]"
            echo "Options:"
            echo -e "\t-k NUM, --keep NUM"
            echo -e "\t\tKeeps last NUM revisions, except current tags"
            echo
            echo -e "\t-d, --dry-run"
            echo -e "\t\tEnables dry run, no changes will be made"
            echo
            echo -e "\t-b, --base-path"
            echo -e "\t\tSets base path of Gitlab Registry repository storage"
            echo
            echo -e "\t-r, --run-gc"
            echo -e "\t\tStarts garbage collector after revision removal"
            exit 0
            ;;

        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
    shift
done

IFS=$'\n'
used_hashes=`mktemp`
marked_hashes=`mktemp`
found=""
regex_tags_mantidas="[0-9]{1,}\.[0-9]{1,}\.[0-9]{1,}|latest|stable"

for repository in `find ${BASE_PATH} -name "_manifests" -type d | sed -e "s#${BASE_PATH}/##" -e "s#/_manifests##"`; do
    echo "# Processing repository: $repository"
    ls ${BASE_PATH}/${repository}/_manifests/tags/*/current/link >/dev/null 2>&1 || { echo "ERROR: Invalid repository. No tags/*/current/link files found"; echo; continue; }
    test -d "${BASE_PATH}/${repository}/_manifests/revisions/sha256" || { echo "ERROR: Invalid repository. revisions/sha256 dir not found"; echo; continue; }

    # Escreve na variavel "used_hashes" conteudo do SHA256 + TAG (ou HASH do Commit) 
    # Ex: ( 9d7bfe1a4b6c05d926ad3ec8526bebeb1a949687b2ae8486b752e817c5ebc5ad c448a7da0ba3dbe83cf072d41c7c869509ab78ca)

    QTD=0
    TOTAL=0
    for tag_hash in $(ls -t ${BASE_PATH}/${repository}/_manifests/tags/*/current/link); do
        img=$(echo ${tag_hash} | grep -P -o '('tags/')(.*)' | cut -d "/" -f2)

        # Mantenho apenas as 3 ultimas imagens que contem o formato ( x.x.x | latest | stable )
        if [[ ${img} =~ (${regex_tags_mantidas}) ]]; 
        then
            if [[ ${QTD} -lt ${KEEP_LAST_IMAGES} ]] 
            then
                echo "$(cat "${tag_hash}" | cut -d':' -f2;) ${img}"
                ((QTD++))
            fi    
        else
            # Mantenho apenas as 3 ultimas imagens que contem ( HASH do commit )
            if [[ ${TOTAL} -lt ${KEEP_LAST_IMAGES} ]] 
            then 
                echo "$(cat "${tag_hash}" | cut -d':' -f2;) ${img}"
            fi
            ((TOTAL++))
        fi    
    done >> "${used_hashes}"

    echo "# Removing revisions SHA256 of $repository:"
    ls -t ${BASE_PATH}/${repository}/_manifests/revisions/sha256 | egrep -v "$(cat ${used_hashes} | awk {'print $1'})" | tee ${marked_hashes}
    if test -s $marked_hashes ; then
      if [ ${DRY_RUN} -ne 1 ]; then
         cat ${marked_hashes} | sed "s#^#${BASE_PATH}/${repository}/_manifests/revisions/sha256/#" | xargs rm -rf && found="true"
      fi
    else
      echo "Nothing to delete"
    fi

    # Remove diretorio das imagens excluidas na fase acima.
    echo "# Removing tags of $repository:"
    ls -t ${BASE_PATH}/${repository}/_manifests/tags | egrep -v "$(cat ${used_hashes} | awk {'print $2'})" | tee ${marked_hashes}
    if test -s $marked_hashes ; then
      if [ ${DRY_RUN} -ne 1 ]; then
         cat ${marked_hashes} | sed "s#^#${BASE_PATH}/${repository}/_manifests/tags/#" | xargs rm -rf && found="true"
      fi
    else
      echo "Nothing to delete"
    fi
    echo
done
rm ${used_hashes}
rm ${marked_hashes}

if [ ${DRY_RUN} -eq 0 -a ${RUN_GARBAGE_COLLECTOR} -eq 1 ]; then
   if test "$found"; then
      "${GITLAB_CTL_COMMAND}" registry-garbage-collect
   else
      echo "Skipping execution of ${GITLAB_CTL_COMMAND} registry-garbage-collect because nothing was deleted"
   fi
fi
