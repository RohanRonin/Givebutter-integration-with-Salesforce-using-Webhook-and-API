public with sharing class GivebutterReprocessFlowAction {

    public class Request {
        @InvocableVariable(label='Staging Record ID' required=true)
        public Id stagingRecordId;
    }

    @InvocableMethod(
        label='Reprocess Givebutter Event'
        description='Reprocesses a failed Givebutter staging event; contact events fetch the latest contact from Givebutter.'
    )
    public static void reprocess(List<Request> requests) {
        if (requests == null || requests.isEmpty()) return;

        Set<Id> stagingIds = new Set<Id>();
        for (Request req : requests) {
            if (req != null && req.stagingRecordId != null) {
                stagingIds.add(req.stagingRecordId);
            }
        }
        if (stagingIds.isEmpty()) return;
        if (stagingIds.size() > 50) {
            throw new ReprocessException('Reprocess no more than 50 staging records at once.');
        }

        List<Givebutter_Event_Staging__c> stagingRecords = [
            SELECT Id, Status__c, Reprocess_Requested__c, Event_Type__c,
                   Givebutter_Record_Id__c
            FROM Givebutter_Event_Staging__c
            WHERE Id IN :stagingIds
            WITH SYSTEM_MODE
        ];

        if (stagingRecords.size() != stagingIds.size()) {
            throw new ReprocessException('One or more staging records could not be found.');
        }

        // Validate every record before changing any records.
        for (Givebutter_Event_Staging__c staging : stagingRecords) {
            if (staging.Status__c != 'Failed') {
                throw new ReprocessException(
                    'Only Failed staging records can be reprocessed. Record: ' + staging.Id +
                    ', Status: ' + staging.Status__c
                );
            }
            if (staging.Reprocess_Requested__c != true) {
                throw new ReprocessException('Reprocess Requested must be checked. Record: ' + staging.Id);
            }
            if (staging.Event_Type__c == 'contact.created' &&
                String.isBlank(staging.Givebutter_Record_Id__c)) {
                throw new ReprocessException(
                    'Givebutter contact ID is missing. Cannot fetch the latest contact for staging record ' + staging.Id
                );
            }
        }

        for (Givebutter_Event_Staging__c staging : stagingRecords) {
            staging.Status__c = 'Received';
            staging.Reprocess_Requested__c = false;
            staging.Next_Retry_At__c = null;
        }
        Database.update(stagingRecords, AccessLevel.SYSTEM_MODE);

        for (Givebutter_Event_Staging__c staging : stagingRecords) {
            Boolean fetchFreshContact = staging.Event_Type__c == 'contact.created';
            System.enqueueJob(
                new GivebutterWebhook.GivebutterEventProcessor(staging.Id, fetchFreshContact)
            );
        }
    }

    public class ReprocessException extends Exception {}
}