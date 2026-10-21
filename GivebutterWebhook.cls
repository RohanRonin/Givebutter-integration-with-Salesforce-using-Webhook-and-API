@RestResource(urlMapping='/givebutter/webhook/*')
global without sharing class GivebutterWebhook {
    
    @HttpPost
    global static void receiveWebhook() {
        
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        System.debug(
    'GIVEBUTTER HEADER NAMES: ' +
    request.headers.keySet()
);
        
        // ========================================================
        // 1. READ REQUEST BODY
        // ========================================================
        
        String requestBody =
            request.requestBody == null
            ? null
            : request.requestBody.toString();
        
        if (String.isBlank(requestBody)) {
            
            response.statusCode = 400;
            
            response.responseBody = Blob.valueOf('{"success":false,"message":"Request body is empty."}');
            return;
        }
        
        // ========================================================
        // 2. READ SIGNATURE
        // ========================================================
        
     String receivedSignature = request.headers.get('Signature');
        
        if (String.isBlank(receivedSignature)) {
            
            response.statusCode = 401;
            
            response.responseBody = Blob.valueOf('{"success":false,"message":"Missing Signature header."}');        
            return;
        }
        
        // ========================================================
        // 3. VERIFY SIGNATURE
        // ========================================================
        
        try {
            
            validateSignature(receivedSignature);
            
        } catch (Exception e) {
            
            response.statusCode = 401;
            
            response.responseBody = Blob.valueOf( '{"success":false,"message":"Invalid webhook signature."}');
            
            return;
        }
        
        // ========================================================
        // 4. PARSE JSON
        // ========================================================
        
        Map<String, Object> payload;
        
        try {
            
            payload = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
            
        } catch (Exception e) {
            
            response.statusCode = 400;
            response.responseBody = Blob.valueOf('{"success":false,"message":"Invalid JSON payload."}');          
            return;
        }
        
        // ========================================================
        // 5. GET EVENT TYPE
        // ========================================================
        
        String eventType = (String)payload.get('event');
        
        if (String.isBlank(eventType)) {
            
            response.statusCode = 400;
            
            response.responseBody = Blob.valueOf('{"success":false,"message":"Event type is missing."}');       
            return;
        }
        
        // ========================================================
        // 6. GET EVENT ID
        // ========================================================
        
        String eventId;
        
        Object eventIdValue =
            payload.get('id');
        
        if (eventIdValue != null) {
            
            eventId =
                String.valueOf(
                    eventIdValue
                );
        }
        
        System.debug(
            'Givebutter Event: ' +
            eventType
        );
        
        System.debug(
            'Givebutter Event ID: ' +
            eventId
        );
        
        // ========================================================
        // 7. GET EVENT DATA
        // ========================================================
        
        Map<String, Object> data;
        
        Object dataValue =
            payload.get('data');
        
        if (
            dataValue instanceof Map<String, Object>
        ) {
            
            data =
                (Map<String, Object>)
                dataValue;
            
        } else {
            
            data =
                new Map<String, Object>();
        }
        
        // ========================================================
        // 8. CREATE STAGING RECORD
        // ========================================================
        // The webhook endpoint only validates and stores the event.
        // Actual Givebutter processing happens asynchronously in the
        // Queueable processor below.
        // ========================================================
        
        try {
            if (String.isBlank(eventId)) {
                response.statusCode = 400;
                response.responseBody = Blob.valueOf(
                    '{"success":false,"message":"Givebutter event ID is missing."}'
                );
                return;
            }
            
            // Prevent the same Givebutter event from being processed twice.
            List<Givebutter_Event_Staging__c> existingEvents = [
                SELECT Id, Status__c
                FROM Givebutter_Event_Staging__c
                WHERE Givebutter_Event_Id__c = :eventId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            
            if (!existingEvents.isEmpty()) {
                System.debug(
                    'Givebutter event already exists. Event ID: ' + eventId
                );
                
                // Givebutter already delivered this event before. Return 200
                // so it does not keep retrying the same webhook.
                response.statusCode = 200;
                response.responseBody = Blob.valueOf(
                    '{"success":true,"message":"Event already received."}'
                );
                return;
            }
            
            Givebutter_Event_Staging__c staging =
                new Givebutter_Event_Staging__c();
            
            staging.Givebutter_Event_Id__c = eventId;
            staging.Event_Type__c = eventType;
            staging.Payload__c = requestBody;
            staging.Status__c = 'Received';
            staging.Received_At__c = System.now();
            staging.Retry_Count__c = 0;
            
            // Store the Givebutter record ID when it is available.
            Object recordIdValue = data.get('id');
            if (recordIdValue != null) {
                staging.Givebutter_Record_Id__c =
                    String.valueOf(recordIdValue);
            }
            
            Database.SaveResult stagingResult =
                Database.insert(staging, false, AccessLevel.SYSTEM_MODE);
            
            if (!stagingResult.isSuccess()) {
                String errorMessage =
                    getDatabaseErrorMessage(stagingResult.getErrors());
                
                // A simultaneous duplicate delivery can reach this point
                // even after the query above, because the field is Unique.
                if (errorMessage != null &&
                    errorMessage.toLowerCase().contains('duplicate')) {
                        response.statusCode = 200;
                        response.responseBody = Blob.valueOf(
                            '{"success":true,"message":"Event already received."}'
                        );
                        return;
                    }
                
                throw new GivebutterStagingException(
                    'Unable to create Givebutter Event Staging record: ' +
                    errorMessage
                );
            }
            
            staging.Id = stagingResult.getId();
            
            // Queue the existing Givebutter business logic.
            System.enqueueJob(
                new GivebutterEventProcessor(staging.Id)
            );
            
            // The event is safely stored. Processing will happen asynchronously.
            response.statusCode = 200;
            response.responseBody = Blob.valueOf(
                '{"success":true,"message":"Webhook received and queued for processing."}'
            );
            
        } catch (Exception e) {
            System.debug(
                'Givebutter staging error: ' + e.getMessage()
            );
            System.debug(e.getStackTraceString());
            
            response.statusCode = 500;
            response.responseBody = Blob.valueOf(
                '{"success":false,"message":"Webhook could not be staged."}'
            );
        }
    }
    
    // ============================================================
    // ASYNC EVENT PROCESSOR
    // ============================================================
    // Reads the original JSON from the staging record and runs the
    // same business logic that previously ran inside receiveWebhook().
    // ============================================================
    public without sharing class GivebutterEventProcessor implements Queueable, Database.AllowsCallouts {
        
        private Id stagingId;
        private Boolean fetchFreshContact;
        
        // Normal webhook processing: use the original staged payload.
        public GivebutterEventProcessor(Id stagingId) {
            this(stagingId, false);
        }
        
        // Manual contact recovery: fetch the current contact from Givebutter first.
        public GivebutterEventProcessor(Id stagingId, Boolean fetchFreshContact) {
            this.stagingId = stagingId;
            this.fetchFreshContact = fetchFreshContact == true;
        }
        
        public void execute(QueueableContext context) {
            
            Givebutter_Event_Staging__c staging = [
                SELECT Id,
                Givebutter_Event_Id__c,
                Event_Type__c,
                Givebutter_Record_Id__c,
                Payload__c,
                Status__c,
                Retry_Count__c,
                Error_Message__c,
                Retry_Reason__c,
                Error_Category__c,
                Next_Retry_At__c,
                Processing_Started__c,
                Processed_At__c,
                Salesforce_Record_Id__c
                FROM Givebutter_Event_Staging__c
                WHERE Id = :stagingId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            
            try {
                // A callout must happen before DML in this transaction.
                // GivebutterReprocessFlowAction explicitly passes true for contact.created
                // events, so manual reprocessing fetches the current Givebutter contact.
                // Normal webhook processing continues to use the original staged payload.
                Boolean shouldFetchFreshContact = fetchFreshContact == true;

                Map<String, Object> data;
                if (shouldFetchFreshContact == true) {
                    if (staging.Event_Type__c != 'contact.created') {
                        throw new GivebutterStagingException(
                            'Fresh-contact recovery is only supported for contact.created events.'
                        );
                    }
                    if (String.isBlank(staging.Givebutter_Record_Id__c)) {
                        // Recover the contact ID from the stored original webhook payload
                        // if the staging lookup field was not populated for some reason.
                        Map<String, Object> storedPayload =
                            (Map<String, Object>) JSON.deserializeUntyped(staging.Payload__c);
                        Object storedDataValue = storedPayload.get('data');
                        if (storedDataValue instanceof Map<String, Object>) {
                            Map<String, Object> storedData = (Map<String, Object>) storedDataValue;
                            Object storedContactId = storedData.get('id');
                            if (storedContactId != null) {
                                staging.Givebutter_Record_Id__c = String.valueOf(storedContactId);
                            }
                        }
                    }
                    if (String.isBlank(staging.Givebutter_Record_Id__c)) {
                        throw new GivebutterStagingException(
                            'Givebutter contact ID is missing from the staging record. Cannot fetch the latest contact.'
                        );
                    }
                    data = GivebutterWebhook.fetchCurrentGivebutterContact(staging.Givebutter_Record_Id__c);
                } else {
                    Map<String, Object> payload =
                        (Map<String, Object>) JSON.deserializeUntyped(staging.Payload__c);
                    data = new Map<String, Object>();
                    Object dataValue = payload.get('data');
                    if (dataValue instanceof Map<String, Object>) {
                        data = (Map<String, Object>) dataValue;
                    }

                    // Fetch current campaign for both create and update events.
                    // Campaign creation is allowed without a default fund.
                    if (staging.Event_Type__c == 'campaign.created' ||
                        staging.Event_Type__c == 'campaign.updated') {
                        String campaignId = data.get('id') == null
                            ? staging.Givebutter_Record_Id__c
                            : String.valueOf(data.get('id'));
                        if (String.isBlank(campaignId)) {
                            throw new GivebutterCampaignException(
                                'Givebutter campaign ID is missing; cannot fetch current campaign.'
                            );
                        }

                        Map<String, Object> webhookData = new Map<String, Object>();
                        webhookData.putAll(data);
                        Map<String, Object> freshCampaign =
                            GivebutterWebhook.fetchCurrentGivebutterCampaign(campaignId);

                        // Fresh API data wins for current settings, while webhook values
                        // remain available for fields omitted by the API.
                        Map<String, Object> mergedCampaign = new Map<String, Object>();
                        mergedCampaign.putAll(webhookData);
                        mergedCampaign.putAll(freshCampaign);

                        String defaultFundReference =
                            GivebutterWebhook.extractDefaultFundId(mergedCampaign);

                        if (!String.isBlank(defaultFundReference)) {
                            // Use the campaign endpoint as the source of truth.
                            // The default_fund value from campaign settings is the
                            // Givebutter reference used for idempotent Salesforce matching.
                            // Do not call /v1/funds/{id}; the campaign may expose a
                            // dashboard/legacy ID that is not a Fund API resource ID.
                            mergedCampaign.put('default_fund_id', defaultFundReference);
                            mergedCampaign.put('fund_id', defaultFundReference);

                            // Use fund metadata only when the campaign response itself
                            // includes it. createOrUpdateGiftDesignation supplies a
                            // stable fallback name when only the ID is available.
                            String campaignFundName = GivebutterWebhook.firstString(
                                mergedCampaign, new List<String>{
                                    'fund_name', 'default_fund_name', 'defaultFundName'
                                }
                            );
                            if (!String.isBlank(campaignFundName)) {
                                mergedCampaign.put('fund_name', campaignFundName);
                            }
                            String campaignFundCode = GivebutterWebhook.firstString(
                                mergedCampaign, new List<String>{
                                    'fund_code', 'default_fund_code', 'defaultFundCode'
                                }
                            );
                            if (!String.isBlank(campaignFundCode)) {
                                mergedCampaign.put('fund_code', campaignFundCode);
                            }
                        }

                        data = mergedCampaign;
                    }
                }

                staging.Status__c = 'Processing';
                staging.Processing_Started__c = System.now();
                staging.Error_Message__c = null;
                staging.Next_Retry_At__c = null;
                Database.update(staging, AccessLevel.SYSTEM_MODE);
                
                Id primarySalesforceRecordId = processEvent(
                    staging.Event_Type__c,
                    data
                );
                
                staging.Salesforce_Record_Id__c =
                    primarySalesforceRecordId;
                
                staging.Status__c = 'Processed';
                staging.Processed_At__c = System.now();
                staging.Next_Retry_At__c = null;
                staging.Retry_Reason__c = null;
                staging.Error_Category__c = null;
                
                Database.update(staging,AccessLevel.SYSTEM_MODE);
                
            } catch (Exception e) {
                // Preserve the actual Salesforce error (including validation,
                // formula/validation-rule, required-field, duplicate, and DML errors)
                // on the staging record so an admin can fix the cause and reprocess.
                Integer currentRetryCount = staging.Retry_Count__c == null
                    ? 0
                    : Integer.valueOf(String.valueOf(staging.Retry_Count__c));
                Integer nextRetryCount = currentRetryCount + 1;
                Boolean transientError = isTransientError(e);
                String detailedError = buildProcessingErrorMessage(e);

                staging.Retry_Count__c = nextRetryCount;
                staging.Error_Message__c = fitFieldLength(
                    Givebutter_Event_Staging__c.Error_Message__c,
                    detailedError
                );
                staging.Retry_Reason__c = fitFieldLength(
                    Givebutter_Event_Staging__c.Retry_Reason__c,
                    detailedError
                );
                // Keep Error_Category__c values compatible with the existing
                // Transient/Permanent picklist and automatic retry policy.
                staging.Error_Category__c = transientError ? 'Transient' : 'Permanent';

                if (transientError && nextRetryCount <= 4) {
                    Integer delayMinutes = getRetryDelayMinutes(nextRetryCount);
                    staging.Status__c = 'Retry Pending';
                    staging.Next_Retry_At__c = System.now().addMinutes(delayMinutes);
                } else {
                    // Validation, formula, required-field, duplicate, and other
                    // non-transient errors stop here until an admin fixes the cause.
                    staging.Status__c = 'Failed';
                    staging.Next_Retry_At__c = null;
                }

                // Try to persist the error on the staging record. Keep error-log
                // creation separate so a staging update failure does not prevent it.
                try {
                    Database.update(staging, AccessLevel.SYSTEM_MODE);
                } catch (Exception stagingUpdateException) {
                    System.debug(LoggingLevel.ERROR,
                        'Unable to update staging error fields for ' + stagingId +
                        ': ' + stagingUpdateException.getMessage());
                }

                createErrorLog(staging, e);
            }
        }
    }
    
    // ============================================================
    // GIVEBUTTER CONTACT API (used by manual Reprocess only)
    // Named Credential: Givebutter_API
    // Base URL: https://api.givebutter.com
    // External Credential should provide Bearer token authentication.
    // ============================================================
    private static Map<String, Object> fetchCurrentGivebutterContact(String contactId) {
        if (String.isBlank(contactId)) {
            throw new GivebutterStagingException('Givebutter contact ID is required for API lookup.');
        }

        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:Givebutter_API/v1/contacts/' + EncodingUtil.urlEncode(contactId, 'UTF-8'));
        request.setMethod('GET');
        request.setHeader('Accept', 'application/json');
        request.setTimeout(120000);

        HttpResponse response = new Http().send(request);
        Integer statusCode = response.getStatusCode();
        if (statusCode < 200 || statusCode >= 300) {
            throw new GivebutterStagingException(
                'Givebutter contact API failed. HTTP ' + statusCode + ': ' + response.getBody()
            );
        }
        if (String.isBlank(response.getBody())) {
            throw new GivebutterStagingException('Givebutter contact API returned an empty response.');
        }

        Object decoded = JSON.deserializeUntyped(response.getBody());
        if (!(decoded instanceof Map<String, Object>)) {
            throw new GivebutterStagingException('Givebutter contact API returned an unexpected JSON response.');
        }
        Map<String, Object> responseMap = (Map<String, Object>) decoded;

        // Support either a direct contact object or a { "data": { ... } } envelope.
        Object dataValue = responseMap.get('data');
        Map<String, Object> contactData;
        if (dataValue instanceof Map<String, Object>) {
            contactData = (Map<String, Object>) dataValue;
        } else {
            contactData = responseMap;
        }

        Object returnedId = contactData.get('id');
        if (returnedId == null) {
            throw new GivebutterStagingException('Givebutter API response did not include a contact ID.');
        }
        if (String.valueOf(returnedId) != contactId) {
            throw new GivebutterStagingException(
                'Givebutter API returned a different contact ID. Expected ' + contactId +
                ', received ' + String.valueOf(returnedId) + '.'
            );
        }
        return contactData;
    }

    // ============================================================
    // GIVEBUTTER CAMPAIGN + FUND API
    // Named Credential: Givebutter_API
    // Base URL: https://api.givebutter.com
    // The callouts are performed before the processor updates staging.
    // ============================================================
    private static Map<String, Object> fetchCurrentGivebutterCampaign(String campaignId) {
        if (String.isBlank(campaignId)) {
            throw new GivebutterCampaignException('Givebutter campaign ID is required for API lookup.');
        }

        HttpRequest request = new HttpRequest();
        request.setEndpoint(
            'callout:Givebutter_API/v1/campaigns/' +
            EncodingUtil.urlEncode(campaignId, 'UTF-8')
        );
        request.setMethod('GET');
        request.setHeader('Accept', 'application/json');
        request.setTimeout(120000);

        HttpResponse response = new Http().send(request);
        Integer statusCode = response.getStatusCode();
        if (statusCode < 200 || statusCode >= 300) {
            throw new GivebutterCampaignException(
                'Givebutter campaign API failed. HTTP ' + statusCode + ': ' + response.getBody()
            );
        }
        if (String.isBlank(response.getBody())) {
            throw new GivebutterCampaignException('Givebutter campaign API returned an empty response.');
        }

        Object decoded = JSON.deserializeUntyped(response.getBody());
        if (!(decoded instanceof Map<String, Object>)) {
            throw new GivebutterCampaignException('Givebutter campaign API returned unexpected JSON.');
        }

        Map<String, Object> responseMap = (Map<String, Object>)decoded;
        Object dataValue = responseMap.get('data');
        Map<String, Object> campaignData = dataValue instanceof Map<String, Object>
            ? (Map<String, Object>)dataValue
            : responseMap;

        Object returnedId = campaignData.get('id');
        if (returnedId == null || String.valueOf(returnedId) != campaignId) {
            throw new GivebutterCampaignException(
                'Givebutter campaign API returned an unexpected campaign ID. Expected ' +
                campaignId + ', received ' + String.valueOf(returnedId) + '.'
            );
        }
        return campaignData;
    }

    // Supports common camelCase/snake_case representations. The actual
    // default-fund key must be confirmed against the response from your account.
    private static String extractDefaultFundId(Map<String, Object> data) {
        if (data == null) {
            return null;
        }

        // Direct ID fields or scalar default_fund value.
        String directId = firstString(data, new List<String>{
            'default_fund_id', 'defaultFundId', 'default_fund', 'defaultFund'
        });
        if (!String.isBlank(directId) &&
            !(data.get('default_fund') instanceof Map<String, Object>) &&
            !(data.get('defaultFund') instanceof Map<String, Object>)) {
            return directId;
        }

        // Nested default-fund objects.
        for (String nestedKey : new List<String>{
            'default_fund', 'defaultFund', 'default_designation', 'defaultDesignation'
        }) {
            Object nestedValue = data.get(nestedKey);
            if (nestedValue instanceof Map<String, Object>) {
                String nestedId = firstString(
                    (Map<String, Object>)nestedValue,
                    new List<String>{'id', 'fund_id', 'fundId'}
                );
                if (!String.isBlank(nestedId)) {
                    return nestedId;
                }
            }
        }

        // Givebutter campaign API settings are an ARRAY, for example:
        // [{"name":"default_fund","value":"71366"}]
        Object settingsValue = data.get('settings');
        if (settingsValue instanceof List<Object>) {
            for (Object item : (List<Object>)settingsValue) {
                if (!(item instanceof Map<String, Object>)) {
                    continue;
                }

                Map<String, Object> setting = (Map<String, Object>)item;
                String settingName = firstString(setting, new List<String>{'name'});
                if (settingName == null ||
                    settingName.trim().toLowerCase() != 'default_fund') {
                    continue;
                }

                Object value = setting.get('value');
                if (value instanceof Map<String, Object>) {
                    return firstString(
                        (Map<String, Object>)value,
                        new List<String>{'id', 'fund_id', 'fundId'}
                    );
                }
                if (value != null && !String.isBlank(String.valueOf(value))) {
                    return String.valueOf(value).trim();
                }
            }
        }

        // Compatibility for settings represented as an object/map.
        if (settingsValue instanceof Map<String, Object>) {
            Map<String, Object> settings = (Map<String, Object>)settingsValue;
            String settingsId = firstString(settings, new List<String>{
                'default_fund_id', 'defaultFundId', 'fund_id', 'fundId'
            });
            if (!String.isBlank(settingsId)) {
                return settingsId;
            }

            Object nestedDefault = settings.get('default_fund');
            if (nestedDefault instanceof Map<String, Object>) {
                return firstString(
                    (Map<String, Object>)nestedDefault,
                    new List<String>{'id', 'fund_id', 'fundId'}
                );
            }
            if (nestedDefault != null && !String.isBlank(String.valueOf(nestedDefault))) {
                return String.valueOf(nestedDefault).trim();
            }
        }

        return null;
    }

    private static String firstString(Map<String, Object> data, List<String> keys) {
        if (data == null || keys == null) return null;
        for (String key : keys) {
            Object value = data.get(key);
            if (value != null && !(value instanceof Map<String, Object>) &&
                !(value instanceof List<Object>)) {
                String textValue = String.valueOf(value).trim();
                if (!String.isBlank(textValue) && textValue.toLowerCase() != 'null') {
                    return textValue;
                }
            }
        }
        return null;
    }

    // Creates/updates the standard GiftDefaultDesignation record connecting
    // a Campaign to its GiftDesignation. Existing defaults for this campaign
    // are replaced with the latest Givebutter default, so the mapping stays current.
    private static void syncGiftDefaultDesignation(
        Id campaignId,
        Id giftDesignationId,
        String givebutterFundId
    ) {
        if (campaignId == null || giftDesignationId == null) {
            throw new GivebutterCampaignException(
                'Campaign ID and Gift Designation ID are required for Gift Default Designation mapping.'
            );
        }

        Schema.SObjectType objectType = Schema.getGlobalDescribe().get('GiftDefaultDesignation');
        if (objectType == null) {
            throw new GivebutterCampaignException(
                'GiftDefaultDesignation is not available. Confirm Fundraising access is enabled.'
            );
        }

        Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
        for (String requiredField : new List<String>{
            'ParentRecordId', 'GiftDesignationId', 'AllocatedPercentage'
        }) {
            if (!fields.containsKey(requiredField)) {
                throw new GivebutterCampaignException(
                    'GiftDefaultDesignation is missing required field ' + requiredField + '.'
                );
            }
        }

        String parentIdText = String.escapeSingleQuotes(String.valueOf(campaignId));
        String queryText =
            'SELECT Id, ParentRecordId, GiftDesignationId, AllocatedPercentage ' +
            'FROM GiftDefaultDesignation WHERE ParentRecordId = \'' + parentIdText + '\'';
        List<SObject> existingDefaults = Database.query(queryText, AccessLevel.SYSTEM_MODE);

        SObject primaryRecord;
        List<SObject> duplicates = new List<SObject>();
        for (SObject existing : existingDefaults) {
            if (primaryRecord == null) {
                primaryRecord = existing;
            } else {
                duplicates.add(existing);
            }
        }

        if (primaryRecord == null) {
            primaryRecord = objectType.newSObject();
            primaryRecord.put('ParentRecordId', campaignId);
        }
        primaryRecord.put('GiftDesignationId', giftDesignationId);
        primaryRecord.put('AllocatedPercentage', 100);

        Database.SaveResult saveResult;
        if (primaryRecord.get('Id') == null) {
            saveResult = Database.insert(primaryRecord, false, AccessLevel.SYSTEM_MODE);
        } else {
            saveResult = Database.update(primaryRecord, false, AccessLevel.SYSTEM_MODE);
        }
        if (!saveResult.isSuccess()) {
            throw new GivebutterCampaignException(
                'Unable to save GiftDefaultDesignation: ' +
                getDatabaseErrorMessage(saveResult.getErrors())
            );
        }

        if (!duplicates.isEmpty()) {
            Database.DeleteResult[] deleteResults =
                Database.delete(duplicates, false, AccessLevel.SYSTEM_MODE);
            for (Database.DeleteResult deleteResult : deleteResults) {
                if (!deleteResult.isSuccess()) {
                    throw new GivebutterCampaignException(
                        'Unable to remove duplicate GiftDefaultDesignation: ' +
                        getDatabaseErrorMessage(deleteResult.getErrors())
                    );
                }
            }
        }

        System.debug(
            'Mapped Givebutter default fund ' + givebutterFundId +
            ' to Campaign ' + campaignId +
            ' using GiftDefaultDesignation and GiftDesignation ' + giftDesignationId
        );
    }

    // ============================================================
    // EVENT ROUTER
    // ============================================================
    // This contains the routing logic that was previously inside
    // receiveWebhook(). It is reusable by the Queueable processor
    // and later by the one-click Reprocess action.
    // ============================================================
    private static Id processEvent(
        String eventType,
        Map<String, Object> data
    ) {
        
        if (eventType == 'contact.created') {
            return handleContact(data);
        }
        else if (eventType == 'transaction.succeeded') {
            return handleTransaction(data);
        }
        else if (eventType == 'campaign.created') {
            return handleCampaign(data);
        }
        else if (eventType == 'campaign.updated') {
            return handleCampaign(data);
        }
        else if (eventType == 'plan.created') {
            return handlePlan(data);
        }
        else if (eventType == 'plan.updated') {
            return handlePlan(data);
        }
        else if (eventType == 'plan.canceled') {
            return handlePlan(data);
        }
        else if (eventType == 'plan.paused') {
            return handlePlan(data);
        }
        else if (eventType == 'plan.resumed') {
            return handlePlan(data);
        }
        else if (eventType == 'plan.failed') {
            return handlePlan(data);
        }
        else if (eventType == 'refund.created') {
            return handleRefund(data);
        }
        else {
            throw new GivebutterStagingException(
                'Event type is not handled: ' + eventType
            );
        }
    }
    
    // ============================================================
    // ERROR LOGGING
    // ============================================================
    private static void createErrorLog(
        Givebutter_Event_Staging__c staging,
        Exception e
    ) {
        
        Givebutter_Integration_Error__c errorLog =
            new Givebutter_Integration_Error__c();
        
        errorLog.Givebutter_Event__c = staging.Id;
        errorLog.Error_Type__c = getErrorType(e);
        errorLog.Error_Message__c = fitFieldLength(
            Givebutter_Integration_Error__c.Error_Message__c,
            buildProcessingErrorMessage(e)
        );
        errorLog.Stack_Trace__c = fitFieldLength(
            Givebutter_Integration_Error__c.Stack_Trace__c,
            e.getStackTraceString()
        );
        errorLog.Retry_Number__c = staging.Retry_Count__c;
        
        Database.SaveResult result =
            Database.insert(errorLog, false, AccessLevel.SYSTEM_MODE);
        
        if (!result.isSuccess()) {
            System.debug(
                'Unable to create Givebutter Integration Error: ' +
                getDatabaseErrorMessage(result.getErrors())
            );
        }
    }
    
    // Builds a useful error string for the staging record and error log.
    // SaveResult errors are already wrapped with Salesforce status codes by
    // getDatabaseErrorMessage(), so messages such as REQUIRED_FIELD_MISSING and
    // FIELD_CUSTOM_VALIDATION_EXCEPTION remain visible to the admin.
    private static String buildProcessingErrorMessage(Exception e) {
        if (e == null) {
            return 'Unknown processing error.';
        }
        String exceptionType = e.getTypeName();
        String message = e.getMessage();
        if (String.isBlank(message)) {
            message = 'No error message was returned by Salesforce.';
        }
        if (String.isBlank(exceptionType)) {
            return message;
        }
        return exceptionType + ': ' + message;
    }

    // Avoid a secondary DML failure if an error message exceeds a field's limit.
    private static String fitFieldLength(Schema.SObjectField fieldToken, String value) {
        if (value == null || fieldToken == null) {
            return value;
        }
        Integer maxLength = fieldToken.getDescribe().getLength();
        if (maxLength != null && maxLength > 0 && value.length() > maxLength) {
            return value.substring(0, maxLength);
        }
        return value;
    }

    private static String getErrorType(Exception e) {
        if (e instanceof GivebutterSignatureException) {
            return 'Authentication';
        }
        if (e instanceof GivebutterSettingsException) {
            return 'Configuration';
        }
        if (e instanceof GivebutterStagingException) {
            return 'Configuration';
        }
        if (e instanceof DmlException) {
            return 'Salesforce DML';
        }
        return 'Unknown';
    }
    private static Integer getRetryDelayMinutes(Integer retryCount) {

    if (retryCount == 1) {
        return 5;
    }

    if (retryCount == 2) {
        return 15;
    }

    if (retryCount == 3) {
        return 60;
    }

    if (retryCount == 4) {
        return 240;
    }

    return null;
}
    
    private static Boolean isTransientError(Exception e) {

    if (e == null) {
        return false;
    }

    String message = e.getMessage();

    if (String.isBlank(message)) {
        return false;
    }

    String errorMessage = message.toLowerCase();

    return errorMessage.contains('timeout')
        || errorMessage.contains('timed out')
        || errorMessage.contains('429')
        || errorMessage.contains('500')
        || errorMessage.contains('502')
        || errorMessage.contains('503')
        || errorMessage.contains('504');
}
    
    // ============================================================
    // CONTACT
    // ============================================================
    
    private static Id handleContact(
        Map<String, Object> data
    ) {
        
        String givebutterContactId;
        
        Object contactIdValue =
            data.get('id');
        
        if (contactIdValue != null) {
            
            givebutterContactId =
                String.valueOf(
                    contactIdValue
                );
        }
        
        String firstName =
            (String)data.get(
                'first_name'
            );
        
        String lastName =
            (String)data.get(
                'last_name'
            );
        
        // Givebutter payloads may provide the email either as
        // primary_email or inside emails: [{ type: 'personal', value: '...' }].
        String email = (String)data.get('primary_email');

        if (String.isBlank(email)) {
            Object emailsValue = data.get('emails');
            if (emailsValue instanceof List<Object>) {
                List<Object> emailList = (List<Object>) emailsValue;
                for (Object emailItem : emailList) {
                    if (emailItem instanceof Map<String, Object>) {
                        Map<String, Object> emailMap =
                            (Map<String, Object>) emailItem;
                        String candidateEmail = (String)emailMap.get('value');
                        if (!String.isBlank(candidateEmail)) {
                            email = candidateEmail.trim();
                            break;
                        }
                    }
                }
            }
        }

        String phone = (String)data.get('primary_phone');

        // Some Givebutter contact payloads keep the phone inside phones[].
        if (String.isBlank(phone)) {
            Object phonesValue = data.get('phones');
            if (phonesValue instanceof List<Object>) {
                List<Object> phoneList = (List<Object>) phonesValue;
                for (Object phoneItem : phoneList) {
                    if (phoneItem instanceof Map<String, Object>) {
                        Map<String, Object> phoneMap =
                            (Map<String, Object>) phoneItem;
                        String candidatePhone = (String)phoneMap.get('value');
                        if (!String.isBlank(candidatePhone)) {
                            phone = candidatePhone.trim();
                            break;
                        }
                    }
                }
            }
        }
        
        Account donor = findOrCreatePersonAccount(
            givebutterContactId,
            firstName,
            lastName,
            email,
            phone
        );
        
        return donor.Id;
    }
    
    
    // ============================================================
    // TRANSACTION
    // ============================================================
    
    private static Id handleTransaction(
        Map<String, Object> data
    ) {
        GiftTransaction gift = processGiftTransaction(data);
        return gift.Id;
    }
    
    // ============================================================
    // CAMPAIGN
    // ============================================================
    
    private static Id handleCampaign(
        Map<String, Object> data
    ) {
        Campaign campaign = createOrUpdateCampaign(data);

        String defaultFundId = extractDefaultFundId(data);

        // A Givebutter campaign can exist without a default fund. In that case,
        // keep the Salesforce Campaign and finish processing successfully.
        // GiftDesignation and GiftDefaultDesignation are created only when the
        // API/webhook data actually supplies a default fund ID. A later
        // campaign.updated event can create the relationship once one is set.
        if (String.isBlank(defaultFundId)) {
            System.debug(LoggingLevel.INFO,
                'Givebutter campaign has no default fund; skipping GiftDesignation sync.');
            return campaign.Id;
        }

        Map<String, Object> fundData = new Map<String, Object>();
        fundData.put('fund_id', defaultFundId);

        String fundName = firstString(data, new List<String>{'fund_name', 'default_fund_name'});
        String fundCode = firstString(data, new List<String>{'fund_code', 'default_fund_code'});
        if (!String.isBlank(fundName)) fundData.put('fund_name', fundName);
        if (!String.isBlank(fundCode)) fundData.put('fund_code', fundCode);

        GiftDesignation designation = createOrUpdateGiftDesignation(fundData);

        syncGiftDefaultDesignation(campaign.Id, designation.Id, defaultFundId);

        return campaign.Id;
    }
    
    
    // ============================================================
    // PLAN
    // ============================================================
    
    private static Id handlePlan(
        Map<String, Object> data
    ) {
        
        // --------------------------------------------------------
        // 1. Create / Update Gift Commitment
        // --------------------------------------------------------
        GiftCommitment commitment = createOrUpdateGiftCommitment(data);
        
        createOrUpdateGiftCommitmentSchedule(data, commitment.Id);
        
        return commitment.Id;
    }
    
    
    // ============================================================
    // REFUND
    // ============================================================
    
    private static Id handleRefund(
        Map<String, Object> data
    ) {
        SObject refund = createOrUpdateGiftRefund(data);
        return (Id)refund.get('Id');
    }
    
    // ============================================================
    // INTEGRATED GIVEBUTTER SERVICES
    // ============================================================
    
    // ------------------------------------------------------------
    // SETTINGS SERVICE
    // ------------------------------------------------------------
    private static Givebutter_Settings__mdt getSettings() {
        Givebutter_Settings__mdt settings = Givebutter_Settings__mdt.getInstance('Default');
        if (settings == null) {
            throw new GivebutterSettingsException('Givebutter Settings Custom Metadata record "Default" was not found.');
        }
        return settings;
    }
    
    private static String getSigningSecret() {
        Givebutter_Settings__mdt settings = getSettings();
        if (String.isBlank(settings.Signing_Secret__c)) {
            throw new GivebutterSettingsException('Givebutter Signing Secret is not configured.');
        }
        return settings.Signing_Secret__c;
    }
    
    // ------------------------------------------------------------
    // SIGNATURE SERVICE
    // ------------------------------------------------------------
    private static Boolean verifySignature(String receivedSignature) {
        if (String.isBlank(receivedSignature)) {
            return false;
        }
        String expectedSignature = getSigningSecret();
        return receivedSignature == expectedSignature;
    }
    
    private static void validateSignature(String receivedSignature) {
        if (!verifySignature(receivedSignature)) {
            throw new GivebutterSignatureException('Invalid Givebutter webhook signature.');
        }
    }
    
    // ------------------------------------------------------------
    // CAMPAIGN SERVICE
    // ------------------------------------------------------------
    private static Campaign createOrUpdateCampaign(Map<String, Object> data) {
        if (data == null) {
            throw new GivebutterCampaignException('Givebutter campaign data is required.');
        }
        
        Object campaignIdValue = data.get('id');
        if (campaignIdValue == null) {
            throw new GivebutterCampaignException('Givebutter campaign ID is required.');
        }
        
        String givebutterCampaignId = String.valueOf(campaignIdValue);
        if (String.isBlank(givebutterCampaignId)) {
            throw new GivebutterCampaignException('Givebutter campaign ID is blank.');
        }
        
        String campaignTitle = (String)data.get('title');
        String campaignCode = (String)data.get('code');
        String campaignDescription = (String)data.get('description');
        
        List<Campaign> existingCampaigns = [
            SELECT Id, Name, Description, Givebutter_Campaign_ID__c, Givebutter_Campaign_Code__c
            FROM Campaign
            WHERE Givebutter_Campaign_ID__c = :givebutterCampaignId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        
        Campaign campaign;
        if (!existingCampaigns.isEmpty()) {
            campaign = existingCampaigns[0];
            System.debug('Existing Salesforce Campaign found: ' + campaign.Id);
        } else {
            campaign = new Campaign();
            campaign.Givebutter_Campaign_ID__c = givebutterCampaignId;
            System.debug('No existing Salesforce Campaign found.');
        }
        
        if (String.isBlank(campaignTitle)) {
            campaign.Name = 'Givebutter Campaign ' + givebutterCampaignId;
        } else {
            campaign.Name = campaignTitle;
        }
        
        if (!String.isBlank(campaignCode)) {
            campaign.Givebutter_Campaign_Code__c = campaignCode;
        }
        
        if (!String.isBlank(campaignDescription)) {
            campaign.Description = campaignDescription;
        }
        
        if (campaign.Id == null) {
            Database.SaveResult result = Database.insert(campaign, false, AccessLevel.SYSTEM_MODE);
            if (!result.isSuccess()) {
                String errorMessage = 'Unable to create Salesforce Campaign.';
                if (!result.getErrors().isEmpty()) {
                    errorMessage = result.getErrors()[0].getMessage();
                }
                throw new GivebutterCampaignException(errorMessage);
            }
            campaign.Id = result.getId();
            System.debug('Created Givebutter Campaign: ' + campaign.Id);
        } else {
            Database.SaveResult result = Database.update(campaign, false, AccessLevel.SYSTEM_MODE);
            if (!result.isSuccess()) {
                String errorMessage = 'Unable to update Salesforce Campaign.';
                if (!result.getErrors().isEmpty()) {
                    errorMessage = result.getErrors()[0].getMessage();
                }
                throw new GivebutterCampaignException(errorMessage);
            }
            System.debug('Updated Givebutter Campaign: ' + campaign.Id);
        }
        
        return campaign;
    }
    
    // ------------------------------------------------------------
    // PERSON ACCOUNT SERVICE
    // ------------------------------------------------------------
    // ------------------------------------------------------------
    // PERSON ACCOUNT SERVICE
    // ------------------------------------------------------------
    // For a contact.created event:
    // - If the Givebutter Contact ID is already linked, update that same
    //   Person Account (idempotent reprocessing).
    // - If the ID is not linked but the email already exists, do NOT update
    //   or insert a Person Account. Throw an actionable error so the staging
    //   record becomes Failed. After the email is corrected in Givebutter,
    //   the existing Reprocess action fetches fresh contact data and retries.
    // - Insert only when neither the Givebutter ID nor email matches.
    private static Account findOrCreatePersonAccount(
        String givebutterContactId,
        String firstName,
        String lastName,
        String email,
        String phone
    ) {
        if (String.isBlank(email)) {
            throw new GivebutterPersonAccountException(
                'Donor email is required. Correct the email in Givebutter, then click Reprocess.'
            );
        }

        String normalizedEmail = email.trim().toLowerCase();

        // 1. Match by Givebutter Contact ID first. Reprocessing the same
        // contact should update the linked record, not create another one.
        if (!String.isBlank(givebutterContactId)) {
            List<Account> linkedAccounts = [
                SELECT Id, FirstName, LastName, PersonEmail, PersonMobilePhone,
                       Givebutter_Contact_ID__c, IsPersonAccount
                FROM Account
                WHERE Givebutter_Contact_ID__c = :givebutterContactId
                WITH SYSTEM_MODE
                ORDER BY CreatedDate ASC
                LIMIT 2
            ];

            if (!linkedAccounts.isEmpty()) {
                Account linked = linkedAccounts[0];
                if (!linked.IsPersonAccount) {
                    throw new GivebutterPersonAccountException(
                        'The Salesforce record linked to Givebutter contact ' +
                        givebutterContactId + ' is not a Person Account.'
                    );
                }

                // If the Givebutter contact is already linked, updating that
                // same record is safe only if its email is not owned by another
                // Person Account.
                List<Account> otherEmailMatches = [
                    SELECT Id, Givebutter_Contact_ID__c, PersonEmail
                    FROM Account
                    WHERE IsPersonAccount = TRUE
                      AND PersonEmail = :normalizedEmail
                      AND Id != :linked.Id
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (!otherEmailMatches.isEmpty()) {
                    throw new GivebutterPersonAccountException(
                        'Email conflict: ' + normalizedEmail +
                        ' is already used by another Person Account (' +
                        otherEmailMatches[0].Id + '). No Account was inserted or updated. ' +
                        'Correct the email in Givebutter, then click Reprocess on this staging record.'
                    );
                }

                return updateMatchedPersonAccount(
                    linked, givebutterContactId, firstName, lastName, normalizedEmail, phone
                );
            }
        }

        // 2. If this is a new/unlinked Givebutter contact but the email
        // already exists, block it. Do NOT reuse or update the existing
        // Person Account and do NOT insert a second one. The processor's
        // catch block will persist the error and set staging Status = Failed.
        List<Account> emailMatches = [
            SELECT Id, FirstName, LastName, PersonEmail,
                   Givebutter_Contact_ID__c, IsPersonAccount
            FROM Account
            WHERE IsPersonAccount = TRUE
              AND PersonEmail = :normalizedEmail
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
            LIMIT 2
        ];

        if (!emailMatches.isEmpty()) {
            Account existingByEmail = emailMatches[0];
            String existingLink = String.isBlank(existingByEmail.Givebutter_Contact_ID__c)
                ? 'not linked to a Givebutter Contact ID'
                : 'linked to Givebutter Contact ID ' + existingByEmail.Givebutter_Contact_ID__c;

            throw new GivebutterPersonAccountException(
                'Duplicate email blocked: ' + normalizedEmail +
                ' already belongs to Salesforce Person Account ' + existingByEmail.Id +
                ' (' + existingLink + '). No Person Account was inserted or updated. ' +
                'Fix the email on the contact in Givebutter, then click Reprocess on this ' +
                'Givebutter Event Staging record. Reprocess will fetch the latest contact from Givebutter.'
            );
        }

        // 3. No ID or email match: insert a new Person Account.
        List<RecordType> personRecordTypes = [
            SELECT Id
            FROM RecordType
            WHERE SObjectType = 'Account' AND IsPersonType = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (personRecordTypes.isEmpty()) {
            throw new GivebutterPersonAccountException(
                'No Person Account record type is available in this Salesforce org.'
            );
        }

        Account donor = new Account();
        donor.RecordTypeId = personRecordTypes[0].Id;
        donor.FirstName = String.isBlank(firstName) ? 'Givebutter' : firstName.trim();
        donor.LastName = String.isBlank(lastName) ? 'Donor' : lastName.trim();
        donor.PersonEmail = normalizedEmail;
        if (!String.isBlank(phone)) {
            donor.PersonMobilePhone = phone.trim();
        }
        if (!String.isBlank(givebutterContactId)) {
            donor.Givebutter_Contact_ID__c = givebutterContactId;
        }

        Database.DMLOptions dmlOptions = new Database.DMLOptions();
        dmlOptions.DuplicateRuleHeader.allowSave = false;
        donor.setOptions(dmlOptions);

        Database.SaveResult result = Database.insert(donor, false, AccessLevel.SYSTEM_MODE);
        if (result.isSuccess()) {
            donor.Id = result.getId();
            System.debug('New Givebutter Person Account created: ' + donor.Id);
            return donor;
        }

        // A duplicate rule may catch a record created after the email query.
        // Do not reuse or update it in this path: block and leave a clear
        // failure on staging so an administrator can correct Givebutter data.
        for (Database.Error error : result.getErrors()) {
            if (error instanceof Database.DuplicateError) {
                Database.DuplicateError duplicateError = (Database.DuplicateError) error;
                Set<Id> duplicateIds = getDuplicateRecordIds(duplicateError.getDuplicateResult());
                if (!duplicateIds.isEmpty()) {
                    throw new GivebutterPersonAccountException(
                        'Salesforce Duplicate Rule blocked creation of Person Account because a ' +
                        'matching record exists (' + String.valueOf(duplicateIds) +
                        '). No existing Account was changed. Correct the email in Givebutter, ' +
                        'then click Reprocess on this staging record.'
                    );
                }
            }
        }

        throw new GivebutterPersonAccountException(
            'Unable to create Person Account: ' + getDatabaseErrorMessage(result.getErrors())
        );
    }

    // Update the Person Account only when it is already linked to this exact
    // Givebutter Contact ID. Email-only matches are deliberately not updated.
    private static Account updateMatchedPersonAccount(
        Account existingDonor,
        String givebutterContactId,
        String firstName,
        String lastName,
        String normalizedEmail,
        String phone
    ) {
        if (existingDonor == null || existingDonor.Id == null || !existingDonor.IsPersonAccount) {
            throw new GivebutterPersonAccountException('A valid existing Person Account was not found.');
        }

        if (String.isBlank(givebutterContactId) ||
            existingDonor.Givebutter_Contact_ID__c != givebutterContactId) {
            throw new GivebutterPersonAccountException(
                'The existing Person Account is not linked to this exact Givebutter Contact ID. ' +
                'No Account was changed.'
            );
        }

        if (!String.isBlank(firstName)) existingDonor.FirstName = firstName.trim();
        if (!String.isBlank(lastName)) existingDonor.LastName = lastName.trim();
        existingDonor.PersonEmail = normalizedEmail;
        if (!String.isBlank(phone)) existingDonor.PersonMobilePhone = phone.trim();

        Database.SaveResult updateResult = Database.update(
            existingDonor, false, AccessLevel.SYSTEM_MODE
        );
        if (!updateResult.isSuccess()) {
            throw new GivebutterPersonAccountException(
                'Unable to update existing Person Account ' + existingDonor.Id + ': ' +
                getDatabaseErrorMessage(updateResult.getErrors())
            );
        }

        System.debug('Updated Person Account already linked to Givebutter Contact: ' + existingDonor.Id);
        return existingDonor;
    }

    private static Set<Id> getDuplicateRecordIds(Datacloud.DuplicateResult duplicateResult) {
        Set<Id> duplicateIds = new Set<Id>();
        if (duplicateResult == null) {
            return duplicateIds;
        }
        
        for (Datacloud.MatchResult matchResult : duplicateResult.getMatchResults()) {
            for (Datacloud.MatchRecord matchRecord : matchResult.getMatchRecords()) {
                SObject duplicateRecord = matchRecord.getRecord();
                if (duplicateRecord != null && duplicateRecord.Id != null) {
                    duplicateIds.add(duplicateRecord.Id);
                }
            }
        }
        
        return duplicateIds;
    }
    
    // ------------------------------------------------------------
    // GIFT DESIGNATION SERVICE
    // ------------------------------------------------------------
    private static GiftDesignation createOrUpdateGiftDesignation(Map<String, Object> data) {
        if (data == null) {
            throw new GivebutterGiftDesignationException('Givebutter fund data is required.');
        }
        
        Object fundIdValue = data.get('fund_id');
        if (fundIdValue == null) {
            throw new GivebutterGiftDesignationException('Givebutter fund ID is required.');
        }
        
        String givebutterFundId = String.valueOf(fundIdValue);
        if (String.isBlank(givebutterFundId)) {
            throw new GivebutterGiftDesignationException('Givebutter fund ID is blank.');
        }
        
        String fundCode = (String)data.get('fund_code');
        String fundName = (String)data.get('fund_name');
        
        List<GiftDesignation> existingDesignations = [
            SELECT Id, Name, IsActive, Description, Givebutter_Fund_ID__c, Givebutter_Fund_Code__c, Givebutter_Fund_Name__c
            FROM GiftDesignation
            WHERE Givebutter_Fund_ID__c = :givebutterFundId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        
        GiftDesignation designation;
        if (!existingDesignations.isEmpty()) {
            designation = existingDesignations[0];
            System.debug('Existing Gift Designation found: ' + designation.Id);
        } else {
            designation = new GiftDesignation();
            designation.Givebutter_Fund_ID__c = givebutterFundId;
            System.debug('No existing Gift Designation found.');
        }
        
        if (!String.isBlank(fundName)) {
            designation.Name = fundName;
        } else if (!String.isBlank(fundCode)) {
            designation.Name = fundCode;
        } else {
            designation.Name = 'Givebutter Fund ' + givebutterFundId;
        }
        
        if (!String.isBlank(fundCode)) {
            designation.Givebutter_Fund_Code__c = fundCode;
        }
        
        if (!String.isBlank(fundName)) {
            designation.Givebutter_Fund_Name__c = fundName;
        }
        
        designation.IsActive = true;
        
        if (designation.Id == null) {
            Database.SaveResult result = Database.insert(designation, false, AccessLevel.SYSTEM_MODE);
            if (!result.isSuccess()) {
                String errorMessage = 'Unable to create Gift Designation.';
                if (!result.getErrors().isEmpty()) {
                    errorMessage = result.getErrors()[0].getMessage();
                }
                throw new GivebutterGiftDesignationException(errorMessage);
            }
            designation.Id = result.getId();
            System.debug('Created Givebutter Gift Designation: ' + designation.Id);
        } else {
            Database.SaveResult result = Database.update(designation, false, AccessLevel.SYSTEM_MODE);
            if (!result.isSuccess()) {
                String errorMessage = 'Unable to update Gift Designation.';
                if (!result.getErrors().isEmpty()) {
                    errorMessage = result.getErrors()[0].getMessage();
                }
                throw new GivebutterGiftDesignationException(errorMessage);
            }
            System.debug('Updated Givebutter Gift Designation: ' + designation.Id);
        }
        
        return designation;
    }
    
    // ------------------------------------------------------------
    // TRANSACTION DESIGNATION SERVICE
    // ------------------------------------------------------------
    private static GiftTransactionDesignation createOrUpdateTransactionDesignation(Map<String, Object> data, Id giftTransactionId) {
        if (data == null) {
            throw new GivebutterGiftTransactionDesignationException('Givebutter transaction data is required.');
        }
        if (giftTransactionId == null) {
            throw new GivebutterGiftTransactionDesignationException('Gift Transaction Id is required.');
        }
        
        Object fundIdValue = data.get('fund_id');
        if (fundIdValue == null) {
            throw new GivebutterGiftTransactionDesignationException('Givebutter fund ID is required.');
        }
        
        String givebutterFundId = String.valueOf(fundIdValue);
        if (String.isBlank(givebutterFundId)) {
            throw new GivebutterGiftTransactionDesignationException('Givebutter fund ID is blank.');
        }
        
        List<GiftDesignation> designations = [
            SELECT Id, Name, Givebutter_Fund_ID__c
            FROM GiftDesignation
            WHERE Givebutter_Fund_ID__c = :givebutterFundId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        
        if (designations.isEmpty()) {
            throw new GivebutterGiftTransactionDesignationException('No Gift Designation found for Givebutter Fund ID: ' + givebutterFundId);
        }
        
        GiftDesignation designation = designations[0];
        
        Decimal transactionAmount;
        Object amountValue = data.get('amount');
        if (amountValue != null) {
            transactionAmount = Decimal.valueOf(String.valueOf(amountValue));
        }
        
        if (transactionAmount == null || transactionAmount < 0) {
            throw new GivebutterGiftTransactionDesignationException('Givebutter transaction amount is required.');
        }
        
        List<GiftTransactionDesignation> existingRecords = [
            SELECT Id, GiftTransactionId, GiftDesignationId, Amount, Percent
            FROM GiftTransactionDesignation
            WHERE GiftTransactionId = :giftTransactionId
            AND GiftDesignationId = :designation.Id
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        
        GiftTransactionDesignation transactionDesignation;
        if (!existingRecords.isEmpty()) {
            transactionDesignation = existingRecords[0];
            System.debug('Existing Gift Transaction Designation found: ' + transactionDesignation.Id);
        } else {
            transactionDesignation = new GiftTransactionDesignation();
            transactionDesignation.GiftTransactionId = giftTransactionId;
            transactionDesignation.GiftDesignationId = designation.Id;
            System.debug('No existing Gift Transaction Designation found.');
        }
        
        transactionDesignation.Amount = transactionAmount;
        transactionDesignation.Percent = 100;
        
        if (transactionDesignation.Id == null) {
            Database.SaveResult result = Database.insert(transactionDesignation, false, AccessLevel.SYSTEM_MODE);
            if (!result.isSuccess()) {
                String errorMessage = 'Unable to create Gift Transaction Designation.';
                if (!result.getErrors().isEmpty()) {
                    errorMessage = result.getErrors()[0].getMessage();
                }
                throw new GivebutterGiftTransactionDesignationException(errorMessage);
            }
            transactionDesignation.Id = result.getId();
            System.debug('Created Gift Transaction Designation: ' + transactionDesignation.Id);
        } else {
            Database.SaveResult result = Database.update(transactionDesignation, false, AccessLevel.SYSTEM_MODE);
            if (!result.isSuccess()) {
                String errorMessage = 'Unable to update Gift Transaction Designation.';
                if (!result.getErrors().isEmpty()) {
                    errorMessage = result.getErrors()[0].getMessage();
                }
                throw new GivebutterGiftTransactionDesignationException(errorMessage);
            }
            System.debug('Updated Gift Transaction Designation: ' + transactionDesignation.Id);
        }
        
        return transactionDesignation;
    }
    
    // ------------------------------------------------------------
    // GIFT TRANSACTION SERVICE
    // ------------------------------------------------------------
    private static GiftTransaction processGiftTransaction(Map<String, Object> data) {
        if (data == null) {
            throw new GivebutterGiftTransactionException('Givebutter transaction data is required.');
        }
        
        Object transactionIdValue = data.get('id');
        if (transactionIdValue == null) {
            throw new GivebutterGiftTransactionException('Givebutter transaction ID is required.');
        }
        
        String givebutterTransactionId = String.valueOf(transactionIdValue);
        if (String.isBlank(givebutterTransactionId)) {
            throw new GivebutterGiftTransactionException('Givebutter transaction ID is blank.');
        }
        
        List<GiftTransaction> existingTransactions = [
            SELECT Id, Name, Givebutter_Transaction_ID__c, PaymentIdentifier, ProcessorReference, DonorId, OriginalAmount, TransactionDate
            FROM GiftTransaction
            WHERE Givebutter_Transaction_ID__c = :givebutterTransactionId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        
        if (!existingTransactions.isEmpty()) {
            GiftTransaction existingGift = existingTransactions[0];
            System.debug('Givebutter Gift Transaction already exists: ' + givebutterTransactionId);
            
            Object existingFundIdValue = data.get('fund_id');
            if (existingFundIdValue != null && !String.isBlank(String.valueOf(existingFundIdValue))) {
                GiftDesignation designation = createOrUpdateGiftDesignation(data);
                System.debug('Gift Designation created/found for existing transaction: ' + designation.Id);
                
                createOrUpdateTransactionDesignation(data, existingGift.Id);
                System.debug('Gift Transaction Designation created/updated for existing transaction: ' + existingGift.Id);
            }
            
            return existingGift;
        }
        
        String firstName = (String)data.get('first_name');
        String lastName = (String)data.get('last_name');
        String email = (String)data.get('email');
        String phone = (String)data.get('phone');
        
        String givebutterContactId;
        Object contactIdValue = data.get('contact_id');
        if (contactIdValue != null) {
            givebutterContactId = String.valueOf(contactIdValue);
        }
        
        if (String.isBlank(email)) {
            throw new GivebutterGiftTransactionException('Donor email is required for transaction ' + givebutterTransactionId);
        }
        
        Account donor = findOrCreatePersonAccount(givebutterContactId, firstName, lastName, email, phone);
        
        Object amountValue = data.get('amount');
        if (amountValue == null) {
            throw new GivebutterGiftTransactionException('Transaction amount is required.');
        }
        
        Decimal amount = Decimal.valueOf(String.valueOf(amountValue));
        
        String paymentMethod = (String)data.get('payment_method');
        if (String.isBlank(paymentMethod)) {
            paymentMethod = (String)data.get('method');
        }
        
        String transactionStatus = (String)data.get('status');
        String transactionNumber = (String)data.get('number');
        String currencyCode = (String)data.get('currency');
        String transactionDateText = (String)data.get('transacted_at');
        
        Date transactionDate;
        if (!String.isBlank(transactionDateText)) {
            Datetime transactionDatetime = (Datetime)JSON.deserialize('"' + transactionDateText + '"', Datetime.class);
            transactionDate = transactionDatetime.date();
        } else {
            transactionDate = Date.today();
        }
        
        Decimal processorFee = getDecimalValue(data, 'fee');
        Decimal donorCoverAmount = getDecimalValue(data, 'fee_covered');
        Decimal donatedAmount = getDecimalValue(data, 'donated');
        Decimal payoutAmount = getDecimalValue(data, 'payout');
        Decimal fairMarketValue = getDecimalValue(data, 'fair_market_value_amount');
        
        Id campaignId;
        Object givebutterCampaignIdValue = data.get('campaign_id');
        if (givebutterCampaignIdValue != null) {
            String givebutterCampaignId = String.valueOf(givebutterCampaignIdValue);
            if (!String.isBlank(givebutterCampaignId) && givebutterCampaignId != '0') {
                List<Campaign> campaigns = [
                    SELECT Id, Name, Givebutter_Campaign_ID__c
                    FROM Campaign
                    WHERE Givebutter_Campaign_ID__c = :givebutterCampaignId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (!campaigns.isEmpty()) {
                    campaignId = campaigns[0].Id;
                }
            }
        }
        
        GiftTransaction gift = new GiftTransaction();
        
        String donorName;
        if (!String.isBlank(firstName) && !String.isBlank(lastName)) {
            donorName = firstName.trim() + ' ' + lastName.trim();
        } else if (!String.isBlank(firstName)) {
            donorName = firstName.trim();
        } else if (!String.isBlank(lastName)) {
            donorName = lastName.trim();
        } else {
            donorName = 'Givebutter Donor';
        }
        
        gift.Name = donorName + ' - ' + amount.setScale(2) + ' - ' + String.valueOf(transactionDate);
        gift.DonorId = donor.Id;
        gift.OriginalAmount = amount;
        
        if (!String.isBlank(paymentMethod)) {
            gift.PaymentMethod = paymentMethod;
        }
        
        gift.Givebutter_Transaction_ID__c = givebutterTransactionId;
        gift.PaymentIdentifier = givebutterTransactionId;
        gift.ProcessorReference = givebutterTransactionId;
        
        if (!String.isBlank(transactionNumber)) {
            gift.Givebutter_Transaction_Number__c = transactionNumber;
        }
        
        gift.TransactionDate = transactionDate;
        
        if (!String.isBlank(transactionStatus)) {
            gift.Status = transactionStatus;
        }
        
        if (!String.isBlank(currencyCode)) {
            gift.CurrencyIsoCode = currencyCode;
        }
        
        if (processorFee != null) {
            gift.ProcessorTransactionFee = processorFee;
        }
        
        if (donorCoverAmount != null) {
            gift.DonorCoverAmount = donorCoverAmount;
        }
        
        if (donatedAmount != null) {
            gift.Givebutter_Donated_Amount__c = donatedAmount;
        }
        
        if (payoutAmount != null) {
            gift.Givebutter_Payout_Amount__c = payoutAmount;
        }
        
        if (fairMarketValue != null) {
            gift.Givebutter_Fair_Market_Value__c = fairMarketValue;
        }
        
        if (campaignId != null) {
            gift.CampaignId = campaignId;
        }
        
        String campaignTitle = (String)data.get('campaign_title');
        if (!String.isBlank(campaignTitle)) {
            gift.Description = campaignTitle;
        }
        
        Database.SaveResult result = Database.insert(gift, false, AccessLevel.SYSTEM_MODE);
        if (!result.isSuccess()) {
            String errorMessage = 'Unable to create Gift Transaction.';
            if (!result.getErrors().isEmpty()) {
                errorMessage = result.getErrors()[0].getMessage();
            }
            throw new GivebutterGiftTransactionException(errorMessage);
        }
        
        gift.Id = result.getId();
        System.debug('Givebutter Gift Transaction created: ' + gift.Id);
        System.debug('Gift Transaction Name: ' + gift.Name);
        
        Object fundIdValue = data.get('fund_id');
        if (fundIdValue != null && !String.isBlank(String.valueOf(fundIdValue))) {
            GiftDesignation designation = createOrUpdateGiftDesignation(data);
            System.debug('Gift Designation created/found: ' + designation.Id);
            
            GiftTransactionDesignation transactionDesignation = createOrUpdateTransactionDesignation(data, gift.Id);
            System.debug('Gift Transaction Designation created/updated: ' + transactionDesignation.Id);
        }
        
        return gift;
    }
    
    // ------------------------------------------------------------
    // GIFT COMMITMENT SERVICE
    // ------------------------------------------------------------
    private static GiftCommitment createOrUpdateGiftCommitment(Map<String, Object> data) {
        if (data == null) {
            throw new GivebutterGiftCommitmentException('Givebutter plan data is required.');
        }
        
        Object planIdValue = data.get('id');
        if (planIdValue == null) {
            throw new GivebutterGiftCommitmentException('Givebutter plan ID is required.');
        }
        
        String givebutterPlanId = String.valueOf(planIdValue);
        if (String.isBlank(givebutterPlanId)) {
            throw new GivebutterGiftCommitmentException('Givebutter plan ID is blank.');
        }
        
        String firstName = (String)data.get('first_name');
        String lastName = (String)data.get('last_name');
        String email = (String)data.get('email');
        String phone = (String)data.get('phone');
        
        String givebutterContactId;
        Object contactIdValue = data.get('contact_id');
        if (contactIdValue != null) {
            givebutterContactId = String.valueOf(contactIdValue);
        }
        
        if (String.isBlank(email)) {
            throw new GivebutterGiftCommitmentException('Donor email is required for Givebutter plan ' + givebutterPlanId);
        }
        
        Account donor = findOrCreatePersonAccount(givebutterContactId, firstName, lastName, email, phone);
        
        Decimal planAmount = getDecimalValue(data, 'amount');
        if (planAmount == null) {
            throw new GivebutterGiftCommitmentException('Givebutter plan amount is required.');
        }
        
        String frequency = (String)data.get('frequency');
        String planStatus = (String)data.get('status');
        String paymentMethod = (String)data.get('method');
        String currencyCode = (String)data.get('currency');
        Date startDate = parseGivebutterDate(data.get('start_at'));
        Date nextBillDate = parseGivebutterDate(data.get('next_bill_date'));
        
        List<GiftCommitment> existingCommitments = [
            SELECT Id, Name, DonorId, Givebutter_Plan_ID__c, NextTransactionAmount, NextTransactionDate, EffectiveStartDate, RecurrenceType, Status, CurrencyIsoCode, Description
            FROM GiftCommitment
            WHERE Givebutter_Plan_ID__c = :givebutterPlanId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        
        GiftCommitment commitment;
        if (!existingCommitments.isEmpty()) {
            commitment = existingCommitments[0];
            System.debug('Existing Gift Commitment found: ' + commitment.Id);
        } else {
            commitment = new GiftCommitment();
            commitment.Givebutter_Plan_ID__c = givebutterPlanId;
            System.debug('No existing Gift Commitment found.');
        }
        
        commitment.DonorId = donor.Id;
        
        String donorName;
        if (!String.isBlank(firstName) && !String.isBlank(lastName)) {
            donorName = firstName.trim() + ' ' + lastName.trim();
        } else if (!String.isBlank(firstName)) {
            donorName = firstName.trim();
        } else if (!String.isBlank(lastName)) {
            donorName = lastName.trim();
        } else {
            donorName = 'Givebutter Donor';
        }
        
        commitment.Name = donorName + ' - Givebutter Recurring Plan - ' + givebutterPlanId;
        commitment.NextTransactionAmount = planAmount;
        
        if (nextBillDate != null) {
            commitment.NextTransactionDate = nextBillDate;
        }
        
        if (startDate != null) {
            commitment.EffectiveStartDate = startDate;
        }
        
        if (!String.isBlank(frequency)) {
            String recurrenceValue = getMatchingPicklistValue(GiftCommitment.RecurrenceType, frequency);
            if (!String.isBlank(recurrenceValue)) {
                commitment.RecurrenceType = recurrenceValue;
            }
        }
        
        if (!String.isBlank(planStatus)) {
            String statusValue = getMatchingPicklistValue(GiftCommitment.Status, planStatus);
            if (!String.isBlank(statusValue)) {
                commitment.Status = statusValue;
            }
        }
        
        if (!String.isBlank(currencyCode)) {
            commitment.CurrencyIsoCode = currencyCode;
        }
        
        String description = 'Givebutter recurring plan';
        if (!String.isBlank(frequency)) {
            description += ' - ' + frequency;
        }
        if (!String.isBlank(paymentMethod)) {
            description += ' - ' + paymentMethod;
        }
        
        commitment.Description = description;
        
        if (commitment.Id == null) {
            Database.SaveResult result = Database.insert(commitment, false, AccessLevel.SYSTEM_MODE);
            if (!result.isSuccess()) {
                String errorMessage = 'Unable to create Gift Commitment.';
                if (!result.getErrors().isEmpty()) {
                    errorMessage = result.getErrors()[0].getMessage();
                }
                throw new GivebutterGiftCommitmentException(errorMessage);
            }
            commitment.Id = result.getId();
            System.debug('Created Givebutter Gift Commitment: ' + commitment.Id);
        } else {
            Database.SaveResult result = Database.update(commitment, false, AccessLevel.SYSTEM_MODE);
            if (!result.isSuccess()) {
                String errorMessage = 'Unable to update Gift Commitment.';
                if (!result.getErrors().isEmpty()) {
                    errorMessage = result.getErrors()[0].getMessage();
                }
                throw new GivebutterGiftCommitmentException(errorMessage);
            }
            System.debug('Updated Givebutter Gift Commitment: ' + commitment.Id);
        }
        
        return commitment;
    }
    
    // ------------------------------------------------------------
    // GIFT COMMITMENT SCHEDULE SERVICE
    // ------------------------------------------------------------
    private static Id createOrUpdateGiftCommitmentSchedule(Map<String, Object> data, Id giftCommitmentId) {
        if (data == null) {
            throw new GivebutterGiftCommitmentScheduleException('Givebutter plan data is required.');
        }
        if (giftCommitmentId == null) {
            throw new GivebutterGiftCommitmentScheduleException('Gift Commitment Id is required.');
        }
        
        String planId = (String) data.get('id');
        if (String.isBlank(planId)) {
            throw new GivebutterGiftCommitmentScheduleException('Givebutter plan id is required.');
        }
        
        Decimal amount = getDecimalValue(data.get('amount'));
        if (amount == null) {
            throw new GivebutterGiftCommitmentScheduleException('Givebutter plan amount is required.');
        }
        
        String frequency = data.get('frequency') == null ? null : String.valueOf(data.get('frequency'));
        String paymentMethod = data.get('method') == null ? null : String.valueOf(data.get('method'));
        
        Date startDate = parseGivebutterDate(data.get('start_at'));
        if (startDate == null) {
            throw new GivebutterGiftCommitmentScheduleException('Givebutter start_at is required.');
        }
        
        Date endDate = parseGivebutterDate(data.get('canceled_at'));
        Date nextBillDate = parseGivebutterDate(data.get('next_bill_date'));
        
        Map<String, Object> schedule = new Map<String, Object>();
        schedule.put('GiftCommitmentId', String.valueOf(giftCommitmentId));
        schedule.put('StartDate', startDate);
        schedule.put('TransactionAmount', amount);
        schedule.put('Givebutter_Plan_ID__c', planId);
        
        if (String.isNotBlank(frequency)) {
            String normalizedFrequency = frequency.trim().toLowerCase();
            if (normalizedFrequency == 'monthly') {
                schedule.put('TransactionInterval', 1);
                schedule.put('TransactionPeriod', 'Monthly');
            } else if (normalizedFrequency == 'quarterly') {
                schedule.put('TransactionInterval', 3);
                schedule.put('TransactionPeriod', 'Monthly');
            } else if (normalizedFrequency == 'yearly' || normalizedFrequency == 'annual' || normalizedFrequency == 'annually') {
                schedule.put('TransactionInterval', 1);
                schedule.put('TransactionPeriod', 'Yearly');
            } else {
                schedule.put('TransactionPeriod', getMatchingPicklistValue('GiftCommitmentSchedule', 'TransactionPeriod', frequency));
                schedule.put('TransactionInterval', 1);
            }
        }
        
        if (nextBillDate != null) {
            schedule.put('TransactionDay', String.valueOf(nextBillDate.day()));
        } else {
            schedule.put('TransactionDay', String.valueOf(startDate.day()));
        }
        
        if (String.isNotBlank(paymentMethod)) {
            String matchingPaymentMethod = getMatchingPicklistValue('GiftCommitmentSchedule', 'PaymentMethod', paymentMethod);
            if (matchingPaymentMethod != null) {
                schedule.put('PaymentMethod', matchingPaymentMethod);
            }
        }
        
        if (endDate != null) {
            schedule.put('EndDate', endDate);
        }
        
        Invocable.Action action = Invocable.Action.createStandardAction('manageRcrGiftCmtSchd');
        action.setInvocationParameter('giftCommitmentSchedule', schedule);
        List<Invocable.Action.Result> results = action.invoke();
        
        if (results == null || results.isEmpty()) {
            throw new GivebutterGiftCommitmentScheduleException('Salesforce returned no result from manageRcrGiftCmtSchd.');
        }
        
        Invocable.Action.Result result = results[0];
        if (!result.isSuccess()) {
            String errorMessage = 'Unknown Salesforce action error.';
            List<Invocable.Action.Error> errors = result.getErrors();
            if (errors != null && !errors.isEmpty()) {
                List<String> messages = new List<String>();
                for (Invocable.Action.Error error : errors) {
                    messages.add(error.getMessage());
                }
                errorMessage = String.join(messages, ' | ');
            }
            throw new GivebutterGiftCommitmentScheduleException('Failed to create Gift Commitment Schedule: ' + errorMessage);
        }
        
        Map<String, Object> outputValues = result.getOutputParameters();
        if (outputValues == null) {
            return null;
        }
        
        Object scheduleIds = outputValues.get('giftCommitmentScheduleIdsList');
        if (scheduleIds == null) {
            return null;
        }
        
        if (scheduleIds instanceof List<Object>) {
            List<Object> ids = (List<Object>) scheduleIds;
            if (!ids.isEmpty()) {
                return (Id) ids[0];
            }
        }
        
        if (scheduleIds instanceof List<String>) {
            List<String> ids = (List<String>) scheduleIds;
            if (!ids.isEmpty()) {
                return (Id) ids[0];
            }
        }
        
        return null;
    }
    
    // ------------------------------------------------------------
    // GIFT REFUND SERVICE
    // ------------------------------------------------------------
    private static SObject createOrUpdateGiftRefund(Map<String, Object> data) {
        if (data == null) {
            throw new GivebutterGiftRefundException('Givebutter refund data is required.');
        }
        
        Schema.SObjectType giftRefundType = Schema.getGlobalDescribe().get('GiftRefund');
        if (giftRefundType == null) {
            throw new GivebutterGiftRefundException('GiftRefund object is not available.');
        }
        
        Schema.DescribeSObjectResult refundDescribe = giftRefundType.getDescribe();
        if (!refundDescribe.isQueryable()) {
            throw new GivebutterGiftRefundException('GiftRefund object is not queryable.');
        }
        
        String refundId = getStringValue(data, 'id');
        if (String.isBlank(refundId)) {
            throw new GivebutterGiftRefundException('Givebutter Refund ID is required.');
        }
        
        String transactionId = getStringValue(data, 'transaction_id');
        if (String.isBlank(transactionId)) {
            throw new GivebutterGiftRefundException('Givebutter Transaction ID is required.');
        }
        
        String escapedRefundId = String.escapeSingleQuotes(refundId);
        String refundQuery = 'SELECT Id, GiftTransactionId, Givebutter_Refund_ID__c, Givebutter_Transaction_ID__c, Givebutter_Refund_Amount__c, Amount, Date, Reason, Status FROM GiftRefund WHERE Givebutter_Refund_ID__c = \'' + escapedRefundId + '\' LIMIT 1';
        
        List<SObject> existingRefunds = Database.query(refundQuery, AccessLevel.SYSTEM_MODE);
        SObject refund = existingRefunds.isEmpty() ? giftRefundType.newSObject() : existingRefunds[0];
        
        List<GiftTransaction> transactions = [
            SELECT Id, Givebutter_Transaction_ID__c, IsPartiallyRefunded, RefundedAmount
            FROM GiftTransaction
            WHERE Givebutter_Transaction_ID__c = :transactionId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        
        if (transactions.isEmpty()) {
            throw new GivebutterGiftRefundException('Gift Transaction was not found for Givebutter Transaction ID: ' + transactionId);
        }
        
        GiftTransaction giftTransaction = transactions[0];
        
        Decimal refundAmount = getDecimalValue(data, 'amount');
        String status = getStringValue(data, 'status');
        String reason = getStringValue(data, 'reason');
        String createdAt = getStringValue(data, 'created_at');
        Date refundDate = parseGivebutterDate(createdAt);
        
        refund.put('GiftTransactionId', giftTransaction.Id);
        refund.put('Givebutter_Refund_ID__c', refundId);
        refund.put('Givebutter_Transaction_ID__c', transactionId);
        
        if (refundAmount != null) {
            refund.put('Amount', refundAmount);
            refund.put('Givebutter_Refund_Amount__c', refundAmount);
        }
        
        if (refundDate != null) {
            refund.put('Date', refundDate);
        }
        
        if (!String.isBlank(reason)) {
            Schema.SObjectField reasonField = giftRefundType.getDescribe().fields.getMap().get('Reason');
            if (reasonField != null) {
                String matchingReason = getMatchingPicklistValue(reasonField, reason);
                if (matchingReason != null) {
                    refund.put('Reason', matchingReason);
                }
            }
        }
        
        if (!String.isBlank(status)) {
            Schema.SObjectField statusField = giftRefundType.getDescribe().fields.getMap().get('Status');
            if (statusField != null) {
                String matchingStatus = getMatchingPicklistValue(statusField, status);
                if (matchingStatus != null) {
                    refund.put('Status', matchingStatus);
                }
            }
        }
        
        if (refund.get('Id') == null) {
            Database.SaveResult insertResult = Database.insert(refund, false, AccessLevel.SYSTEM_MODE);
            if (!insertResult.isSuccess()) {
                throw new GivebutterGiftRefundException('Failed to create Gift Refund: ' + getDatabaseErrorMessage(insertResult.getErrors()));
            }
        } else {
            Database.SaveResult updateResult = Database.update(refund, false, AccessLevel.SYSTEM_MODE);
            if (!updateResult.isSuccess()) {
                throw new GivebutterGiftRefundException('Failed to update Gift Refund: ' + getDatabaseErrorMessage(updateResult.getErrors()));
            }
        }
        
        return refund;
    }
    
    // ------------------------------------------------------------
    // UTILITY & EXCEPTION HELPERS
    // ------------------------------------------------------------
    private static String getStringValue(Map<String, Object> data, String fieldName) {
        if (data == null || !data.containsKey(fieldName)) {
            return null;
        }
        Object value = data.get(fieldName);
        if (value == null) {
            return null;
        }
        String result = String.valueOf(value);
        if (result == 'null') {
            return null;
        }
        return result;
    }
    
    private static Decimal getDecimalValue(Map<String, Object> data, String fieldName) {
        if (data == null) {
            return null;
        }
        return getDecimalValue(data.get(fieldName));
    }
    
    private static Decimal getDecimalValue(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal)value;
        }
        String valueText = String.valueOf(value);
        if (String.isBlank(valueText) || valueText == 'null') {
            return null;
        }
        return Decimal.valueOf(valueText);
    }
    
    private static Date parseGivebutterDate(Object value) {
        if (value == null) {
            return null;
        }
        String dateText = String.valueOf(value).trim();
        if (String.isBlank(dateText) || dateText == 'null') {
            return null;
        }
        try {
            if (dateText.length() == 10 && !dateText.contains('T') && !dateText.contains(' ')) {
                return Date.valueOf(dateText);
            }
            String datePart = dateText.contains(' ') ? dateText.substringBefore(' ') : dateText;
            if (datePart.contains('T')) {
                datePart = datePart.substringBefore('T');
            }
            if (datePart.length() == 10 && datePart.contains('-')) {
                List<String> parts = datePart.split('-');
                if (parts.size() == 3) {
                    return Date.newInstance(Integer.valueOf(parts[0]), Integer.valueOf(parts[1]), Integer.valueOf(parts[2]));
                }
            }
            return Date.valueOf(datePart);
        } catch (Exception e) {
            throw new GivebutterGiftCommitmentException('Unable to parse Givebutter date: ' + dateText);
        }
    }
    
    private static String getMatchingPicklistValue(Schema.SObjectField fieldToken, String givebutterValue) {
        if (fieldToken == null || String.isBlank(givebutterValue)) {
            return null;
        }
        String normalizedGivebutterValue = givebutterValue.trim().toLowerCase();
        for (Schema.PicklistEntry entry : fieldToken.getDescribe().getPicklistValues()) {
            if (!entry.isActive()) {
                continue;
            }
            String salesforceValue = entry.getValue();
            if (salesforceValue.toLowerCase() == normalizedGivebutterValue || entry.getLabel().toLowerCase() == normalizedGivebutterValue) {
                return salesforceValue;
            }
        }
        return null;
    }
    
    private static String getMatchingPicklistValue(String objectName, String fieldName, String incomingValue) {
        if (String.isBlank(incomingValue)) {
            return null;
        }
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        if (!globalDescribe.containsKey(objectName)) {
            return incomingValue;
        }
        Schema.DescribeSObjectResult objectDescribe = globalDescribe.get(objectName).getDescribe();
        Schema.SObjectField field = objectDescribe.fields.getMap().get(fieldName);
        if (field == null) {
            return incomingValue;
        }
        Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
        if (fieldDescribe.getType() != Schema.DisplayType.Picklist) {
            return incomingValue;
        }
        
        String normalizedIncoming = incomingValue.trim().toLowerCase();
        for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
            if (!entry.isActive()) {
                continue;
            }
            if (entry.getValue().trim().toLowerCase() == normalizedIncoming) {
                return entry.getValue();
            }
        }
        
        if (fieldName == 'TransactionPeriod') {
            if (normalizedIncoming == 'monthly') {
                return findPicklistValue(fieldDescribe, new Set<String>{'monthly', 'month'});
            }
            if (normalizedIncoming == 'yearly') {
                return findPicklistValue(fieldDescribe, new Set<String>{'yearly', 'year', 'annual', 'annually'});
            }
        }
        
        if (fieldName == 'PaymentMethod') {
            if (normalizedIncoming == 'card') {
                return findPicklistValue(fieldDescribe, new Set<String>{'card', 'credit card', 'creditcard'});
            }
        }
        
        return null;
    }
    
    private static String findPicklistValue(Schema.DescribeFieldResult fieldDescribe, Set<String> possibleValues) {
        for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
            if (!entry.isActive()) {
                continue;
            }
            if (possibleValues.contains(entry.getValue().trim().toLowerCase())) {
                return entry.getValue();
            }
        }
        return null;
    }
    
    private static String getDatabaseErrorMessage(Database.Error[] errors) {
        if (errors == null || errors.isEmpty()) {
            return 'Unknown database error.';
        }
        String message = '';
        for (Database.Error error : errors) {
            if (!String.isBlank(message)) {
                message += ' | ';
            }
            message += error.getStatusCode() + ': ' + error.getMessage();
        }
        return message;
    }
    
    public class GivebutterStagingException extends Exception {}
    public class GivebutterSettingsException extends Exception {}
    public class GivebutterSignatureException extends Exception {}
    public class GivebutterCampaignException extends Exception {}
    public class GivebutterPersonAccountException extends Exception {}
    public class GivebutterGiftDesignationException extends Exception {}
    public class GivebutterGiftTransactionDesignationException extends Exception {}
    public class GivebutterGiftTransactionException extends Exception {}
    public class GivebutterGiftCommitmentException extends Exception {}
    public class GivebutterGiftCommitmentScheduleException extends Exception {}
    public class GivebutterGiftRefundException extends Exception {}
}