#!/bin/bash

#
# ABOUT
#
#       This script looks at your list of local branches, extracts
#       issue numbers from the branch names, checks which issues
#       have been merged, deletes the merged branches, and then
#       deletes the remote copies of the merged branches.
#
#       This makes use of the github `POST /repos/:user/:repo/pulls/:issue/merge`
#       endpoint. 
#       More info on that is available at http://developer.github.com/v3/pulls/
#
# USAGE
#
#       $ sh delete_merged_pulls.sh [options] [feature_branch]
#
# OPTIONS
#
#       -u --user   - github username (not needed when passing --token, or using a saved token)
#       -p --password - github password (not needed when passing --token, or using a saved token)
#       --save - save access token for future use
#       -t --token - github oauth token
#       -i --issue  - issue number
#       -b --base   - the branch you want your changes pulled into. default: master
#       --base-account - the account containing issue and the base branch to merge into
#       --base-repo - the github repository name
#       
#       feature-branch - the branch (or git ref) where your changes are implemented
#                        feature branch is assumed to be user/feature-branch if no
#                        user is specified. default: working branch name (or prompted)
#
#
# CONFIGURATION
#
#       If available, this script uses the config values from git-open-pull. When not available,
#       they will be requested on the command line. Note storing your git password this way is
#       not secure.
#
#       [github]
#               user = ....
#               password = ....
#       [gitOpenPull]
#               token = .....
#               baseAccount = ....
#               baseRepo = .....
#               base = master
PYTHON_CMD="/bitly/local/bin/python"
[ $? != 0 ] && echo "unable to find 'python' command" && exit 1;
GIT_CMD=`/usr/bin/which git`
[ $? != 0 ] && echo "unable to find 'git' command" && exit 1;

# grab defaults where we can
#####################
BASE_ACCOUNT=`$GIT_CMD config --get gitOpenPull.baseAccount`
BASE_REPO=`$GIT_CMD config --get gitOpenPull.baseRepo`
BASE_BRANCH=`$GIT_CMD config --get gitOpenPull.base || echo "master"`
GITHUB_USER=`$GIT_CMD config --get github.user`
GITHUB_PASSWORD=`$GIT_CMD config --get github.password`
GITHUB_TOKEN=`$GIT_CMD config --get gitOpenPull.token`
FEATURE_BRANCH=`$GIT_CMD describe --contains --all HEAD`

function get_issue_number()
{
    local branch_name=$1
    local issue_number=`echo $branch_name | perl -p -e 's/.*_([0-9]+)$/\1/'`
    if [ "$issue_number" == "$branch_name" ]; then
        issue_number=`echo $branch_name | perl -p -e 's/^([0-9]+)_.*/\1/'`
    fi
    if [ "$issue_number" != "$branch_name" ]; then
        echo $issue_number
    fi
}

function issue_status() {
    local _ISSUE_NUMBER=$1
    # now lookup issue information
    # endpoint => /repos/:user/:repo/issues/:id
    local endpoint="https://api.github.com/repos/$BASE_ACCOUNT/$BASE_REPO/issues/$_ISSUE_NUMBER?access_token=$GITHUB_TOKEN"
    local ISSUE_JSON=`curl --silent -H "Accept: application/vnd.github-issue.text+json,application/json" $endpoint`
    local ISSUE_STATE=$(echo $ISSUE_JSON | $PYTHON_CMD -c '
try:
    import simplejson as json
except ImportError:
    import json
import sys
data = sys.stdin.read().strip().replace("\n",r"\n").replace("\r","")
open("/tmp/issue.json", "w").write(data)
data = json.loads(data)
if "message" in data:
    print "ERROR verifying issue number: ", data["message"]
else:
    print data.get("state", "unknown-issue")
')
    if [ $? != 0 ]; then
        echo "-"
    elif [[ "$ISSUE_STATE" =~ "ERROR" ]]; then
        echo "error: $ISSUE_STATE"
    else
        echo $ISSUE_STATE
    fi

}

# parse the command line args
#####################
while [ "$1" != "" ]; do
    PARAM=`echo "$1" | awk -F= '{print $1}'`
    VALUE=`echo "$1" | awk -F= '{print $2}'`
    case $PARAM in
        -u | --user)
            GITHUB_USER="$VALUE"
            ;;
        -p | --password)
            GITHUB_PASSWORD="$VALUE"
            ;;
        -t | --token)
            GITHUB_TOKEN="$VALUE"
            ;;
        --base-account)
            BASE_ACCOUNT="$VALUE"
            ;;
        --base-repo)
            BASE_REPO="$VALUE"
            ;;
        -b | --base)
            BASE_BRANCH="$VALUE"
            ;;
        -i | --issue)
            ISSUE_NUMBER="$VALUE"
            ;;
        --save)
            SAVE_ACCESS_TOKEN=1
            ;;
        * )
            FEATURE_BRANCH="$1"
            ;;
    esac
    shift
done


# prompt for values as needed
#####################
if [ -z "$GITHUB_TOKEN" ]; then
    
    if [ -z "$GITHUB_USER" ]; then
        read -p "github username: " GITHUB_USER
    fi
    if [ -z "$GITHUB_PASSWORD" ]; then
        echo "using github username: $GITHUB_USER"
        # turn off echo to the shell
        stty -echo 
        read -p "github password: " GITHUB_PASSWORD; echo
        stty echo
    fi

    # now we need to get an oauth token
    # this asks for access to private repos because, well, obviously you could be using this
    # script for a private repo
    echo "... getting access token (run with --save to save access token)"
    endpoint="https://api.github.com/authorizations"
    OAUTH_JSON=`curl --silent -u "$GITHUB_USER:$GITHUB_PASSWORD" -d '{"scopes":["repo"]}' $endpoint`
    GITHUB_TOKEN=$(echo $OAUTH_JSON | $PYTHON_CMD -c '
try:
    import simplejson as json
except ImportError:
    import json
import sys
data = sys.stdin.read().strip().replace("\n",r"\n").replace("\r","")
data = json.loads(data)
if "token" in data:
    print data["token"]
')

    if [ -z "$GITHUB_TOKEN" ]; then
        echo $OAUTH_JSON
        exit 1;
    fi
    
    # conditionally save the access token
    if [ "$SAVE_ACCESS_TOKEN" == "1" ]; then
        $GIT_CMD config gitOpenPull.token "$GITHUB_TOKEN"
    fi
else
    echo "... using saved access token"
fi

if [ -z "$BASE_ACCOUNT" ]; then
    read -p "destination github username (account to pull code into): " BASE_ACCOUNT
    $GIT_CMD config gitOpenPull.baseAccount $BASE_ACCOUNT
fi

if [ -z "$BASE_REPO" ]; then
    read -p "github repsitory name (ie: github.com/$BASE_ACCOUNT/___): " BASE_REPO
    $GIT_CMD config gitOpenPull.baseRepo $BASE_REPO
fi


# validate remote information
##############################

# branch should be separated with ':'
FEATURE_BRANCH=$(echo $FEATURE_BRANCH | sed -e 's/\//:/g')
# if username part was not specified, assume it's the github username
if ! echo $FEATURE_BRANCH | egrep -q ':'; then
    FEATURE_BRANCH="$GITHUB_USER:$FEATURE_BRANCH"
fi

merged_branches=""

current_branch="$(git branch | grep "*" | awk '{print $2}')"
if [ "$current_branch" != "" -a "$current_branch" != "master" \
        -a "$current_branch" != "bitly_master" ]
then
    echo ""
    echo "WARNING: You are currently on $current_branch so we can't do anything with it."
    echo "Skipping $current_branch"
    echo ""
fi

for branch in $(git branch | grep -v "*" | sort)
do
    issue_number=$(get_issue_number $branch)
    if [ "$issue_number" == "" ]
    then
        echo "  Skipping $branch"
        continue
    fi

    echo -n "  Checking issue $issue_number... "

    this_issue_status=$(issue_status $issue_number)
    # endpoint="https://api.github.com/repos/$BASE_ACCOUNT/$BASE_REPO/pulls/$issue_number/merge"
    # merge_status=`curl --silent -w %{http_code} "$endpoint?access_token=$GITHUB_TOKEN" -o /dev/null`

    if [ "$this_issue_status" == "closed" ]
    then
        # has been closed
        merged_branches="$merged_branches $branch"
        echo "==> Closed. Adding $branch to delete list."
    else
        echo "Still open. [$branch]"
    fi
done


if [ "$merged_branches" == "" ]
then
    echo "You seem to be all clean and up to date. Congrats!"
else
    echo "git branch -D $merged_branches..."
    echo -n "Ready? y/[n] "
    read x

    if [ "$x" == "y" ]
    then
        echo "$merged_branches" | xargs git branch -D 
    else
        echo "Aborting."
        exit
    fi

    echo -n "Clean up remotes, too?  y/[n] "
    read x
        if [ "$x" == "y" ]
    then
        remote_branches=$(git branch -r | grep mrwoof\/ | cut -d'/' -f 2)
        
        if [ "$remote_branches" = "" ]; then
            echo "No remote branches. Quitting."
            exit
        fi
        
        delete_branches=""
        confirm_msg=""
        for branch in $remote_branches; do    
            local_branch=`git branch | grep " $branch\$"`
            if [ "$local_branch" = "" ]; then
                delete_branches="$delete_branches $branch"
                confirm_msg="$confirm_msg\n    $branch"
            fi
        done
        
        if [ "$delete_branches" = "" ]; then
            echo "No orphan remote branches. Quitting."
            exit
        fi
        
        for branch in $delete_branches; do
             echo "DELETING $branch"
             git push mrwoof :$branch
        done
    else
        exit
    fi

    echo "Done."

fi