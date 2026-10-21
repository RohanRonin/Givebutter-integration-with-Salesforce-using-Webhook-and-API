public with sharing class GivebutterCampaignApiService {

    public class Request {
        @InvocableVariable(required=true)
        public Id campaignId;
    }

    @InvocableMethod(label='Create Givebutter Campaign'description='Creates a Givebutter campaign from a Salesforce Campaign')
    public static void createCampaign(List<Request> requests) {

        for (Request request : requests) {

            if (request.campaignId != null) {
                System.enqueueJob(new CreateCampaignJob(request.campaignId));
            }
        }
    }


    public class CreateCampaignJob implements Queueable, Database.AllowsCallouts {

        private Id campaignId;

        public CreateCampaignJob(Id campaignId) {
            this.campaignId = campaignId;
        }

        public void execute(QueueableContext context) {

            Campaign campaign = [
    SELECT Id,
           Name,
           Description,
           Givebutter_Campaign_ID__c
    FROM Campaign
    WHERE Id = :campaignId
    LIMIT 1
];


            /*
             * Don't create another Givebutter campaign
             * if this Salesforce Campaign is already connected.
             */
            if (campaign.Givebutter_Campaign_ID__c != null) {
                System.debug(
                    'Givebutter Campaign already exists: ' +
                    campaign.Givebutter_Campaign_ID__c
                );
                return;
            }


            /*
             * Build Givebutter request body
             */
            Map<String, Object> body = new Map<String, Object>();

            body.put('type', 'fundraise');
            body.put('title', campaign.Name);

            if (campaign.Description != null) {
                body.put('description', campaign.Description);
            }


            /*
             * Create HTTP request
             */
            HttpRequest req = new HttpRequest();

            req.setEndpoint(
                'callout:Givebutter_API/v1/campaigns'
            );

            req.setMethod('POST');

            req.setHeader(
                'Content-Type',
                'application/json'
            );

            req.setHeader(
                'Accept',
                'application/json'
            );

            req.setBody(
                JSON.serialize(body)
            );


            /*
             * Send request
             */
            Http http = new Http();

            HttpResponse res = http.send(req);


            System.debug(
                'Givebutter Status Code: ' +
                res.getStatusCode()
            );

            System.debug(
                'Givebutter Response: ' +
                res.getBody()
            );


            /*
             * Successful creation
             */
if (res.getStatusCode() == 201) {

    System.debug('===== GIVEBUTTER SUCCESS =====');

    System.debug(
        'Raw Givebutter Response: ' +
        res.getBody()
    );

    Map<String, Object> responseBody =
        (Map<String, Object>) JSON.deserializeUntyped(
            res.getBody()
        );

    System.debug(
        'Parsed Response: ' +
        responseBody
    );

    System.debug(
        'Response contains ID: ' +
        responseBody.containsKey('id')
    );

    Object idValue =
        responseBody.get('id');

    System.debug(
        'ID returned by Givebutter: ' +
        idValue
    );

    if (idValue == null) {

        System.debug(
            'ERROR: Givebutter did not return an ID.'
        );

        return;
    }

    String givebutterId =
        String.valueOf(idValue);

    System.debug(
        'Givebutter ID to save: ' +
        givebutterId
    );

    Campaign campaignToUpdate =
        new Campaign(
            Id = campaignId,
            Givebutter_Campaign_ID__c =
                givebutterId
        );

    update campaignToUpdate;

    System.debug(
        'SUCCESS: Givebutter ID saved to Salesforce: ' +
        givebutterId
    );

            } else {

                System.debug('Givebutter Campaign creation failed.');

                System.debug('Status: ' + res.getStatusCode());

                System.debug('Response: ' + res.getBody());
            }
        }
    }
}