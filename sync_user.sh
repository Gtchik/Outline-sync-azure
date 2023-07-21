script_dir="$(cd "$(dirname "$0")" && pwd)"

if [[ -f "$script_dir/.env" ]]; then
    # Load the environment variables from the .env file
    source "$script_dir/.env"
else
    echo `date +%y/%m/%d_%H:%M:%S` : "The .env file does not exist. Please create it with the appropriate environment variables."  >> "$script_dir/user_sync.log"
    exit 1
fi


server_information=$(curl --insecure $OUTLINE_MANAGEMENT_API_URL/server/)
name_server=$(echo $server_information | jq '.name')
hostname_server=$(echo $server_information | jq '.hostnameForAccessKeys')


echo `date +%y/%m/%d_%H:%M:%S` : "Start user sync" >> "$script_dir/user_sync.log"

# Get an access token using the client ID and client secret
response=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=client_credentials&client_id=${MICROSOFT_CLIENT_ID}&client_secret=${MICROSOFT_CLIENT_SECRET}&scope=https://graph.microsoft.com/.default" "https://login.microsoftonline.com/${MICROSOFT_TENANT_ID}/oauth2/v2.0/token")
access_token=$(echo $response | jq -r .access_token)


azure_members_name=$(curl -X GET -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" "https://graph.microsoft.com/v1.0/groups/$MICROSOFT_ID_GROUP/members?\$select=displayName,mail,jobTitle,id" | jq '[.value[] | {id: .id, azureName: (.displayName + ":" + .jobTitle + ":" + .mail + ":" + .id)}]')

outline_members=$(curl --insecure $OUTLINE_MANAGEMENT_API_URL/access-keys/ | jq '[.accessKeys[] | {id: .id, name: .name}]')

#Remove users from "outline" that no longer exist in the Azure list.
for row in $(echo "${outline_members}" | jq -r '.[] | @base64'); do
    _jq() {
        echo ${row} | base64 --decode | jq -r ${1}
    }
     outlineName=$(_jq '.name')
    #Check if Outline user longer exist in Azure list
    if [ ! $(echo $azure_members_name | jq --arg outlineName "$outlineName" '.[] | select(.azureName==$outlineName) | length > 0') ]; then
        #The Outline user no more exist on Azure
        #Check if the id exist (could happen when the job title was chaged for exemple)
        outline_uid=$(echo "$outlineName" | cut -d':' -f4)
        if [ $(echo $azure_members_name | jq --arg outline_uid "$outline_uid" '.[] | select(.id==$outline_uid) | length > 0') ]; then
            new_name=$(echo $azure_members_name | jq --arg outline_uid "$outline_uid" '.[] | select(.id==$outline_uid) | .azureName')
            echo `date +%y/%m/%d_%H:%M:%S` : "Update user $uid : from $outlineName to $new_name" >> "$script_dir/user_sync.log"
            uid=$(_jq '.id')
            curl --insecure -X PUT -F "name=$new_name" "$OUTLINE_MANAGEMENT_API_URL/access-keys/$uid/name"
        else
            #User no longer exist
            uid=$(_jq '.id')
            echo `date +%y/%m/%d_%H:%M:%S` : "Delete user $uid : $outlineName" >> "$script_dir/user_sync.log"
            #Delete the new user from outline 
            curl --insecure -X DELETE "$OUTLINE_MANAGEMENT_API_URL/access-keys/$uid"
            #Send a delete email 
            address_email=$(echo "$outlineName" | cut -d':' -f3)
            if [ -z $address_email ]
            then
                echo `date +%y/%m/%d_%H:%M:%S` :  "No mail address for user $uid : $outlineName" >> "$script_dir/user_sync.log"
            else
                cat "$script_dir/mail/goodbye.html" | sed "s#\[COMPANY_NAME\]#$COMPANY_NAME#g" | sed "s#\[IP_SERVER\]#$hostname_server#g" | sed "s#\[NAME_SERVER\]#$name_server#g" | sudo mail -s "$(echo -e 'Account Termination Confirmation for Outline VPN \nContent-Type: text/html\nMime-Version: 1.0')" $address_email
            fi
        fi
    fi
done

outline_members=$(curl --insecure $OUTLINE_MANAGEMENT_API_URL/access-keys/ | jq '[.accessKeys[] | {id: .id, name: .name, azureUId: (.name | split(":")[3]) }]')
#Add new Azure users in Outline
for row in $(echo "${azure_members_name}" | jq -r '.[] | @base64'); do
    _jq() {
        echo ${row} | base64 --decode | jq -r ${1}
    }
    azureResponseID=$(_jq '.id')
    azureName=$(_jq '.azureName')
    #Check if Azure user already exist in outline
    if [[ ! $(echo $outline_members | jq --arg azureResponseID "$azureResponseID" '.[] | select(.azureUId==$azureResponseID) | length > 0') ]]; then
        #The Azure user don't exist on outline 
        echo `date +%y/%m/%d_%H:%M:%S` : "Create $azureName" >> "$script_dir/user_sync.log"
        #Create a new user on outline 
        new_user=$(curl --insecure -X POST "$OUTLINE_MANAGEMENT_API_URL/access-keys"  )
        new_user_id=$(echo $new_user | jq '.id' | tr -d '"')
        new_user_access_key=$(echo $new_user | jq '.accessUrl' | tr -d '"')
        #rename the user
        curl --insecure -X PUT -F "name=$azureName" "$OUTLINE_MANAGEMENT_API_URL/access-keys/$new_user_id/name"
        #Send a welcome email with the access key
        address_email=$(echo "$azureName" | cut -d':' -f3)
        cat "$script_dir/mail/welcome.html" | sed "s#\[COMPANY_NAME\]#$COMPANY_NAME#g" | sed "s#\[ACCESS_KEY\]#$new_user_access_key#g" | sed "s#\[IP_SERVER\]#$hostname_server#g" | sed "s#\[NAME_SERVER\]#$name_server#g" | sudo mail -s "$(echo -e 'Get started with Outline VPN: Your Account Information. \nContent-Type: text/html\nMime-Version: 1.0')" $address_email 
    fi
done

echo `date +%y/%m/%d_%H:%M:%S` : "End user sync" >> "$script_dir/user_sync.log"
