public with sharing class GivebutterFundApiService {

    public class Request {

        @InvocableVariable(required=true)
        public Id giftDefaultDesignationId;
    }


    @InvocableMethod(label='Create Givebutter Fund'
        description='Creates a Givebutter Fund from a Gift Default Designation'
    )
    public static void createFund(List<Request> requests) {

        for (Request request : requests) {

            if (request.giftDefaultDesignationId != null) {

                System.enqueueJob(
                    new CreateFundJob(
                        request.giftDefaultDesignationId
                    )
                );
            }
        }
    }


    public class CreateFundJob implements Queueable, Database.AllowsCallouts {

        private Id giftDefaultDesignationId;


        public CreateFundJob(Id giftDefaultDesignationId) {

            this.giftDefaultDesignationId =
                giftDefaultDesignationId;
        }


        public void execute(QueueableContext context) {

            // --------------------------------------------------
            // 1. Get Gift Default Designation
            // --------------------------------------------------

            GiftDefaultDesignation defaultDesignation = [

                SELECT
                    Id,
                    GiftDesignationId,
                    ParentRecordId

                FROM GiftDefaultDesignation

                WHERE Id = :giftDefaultDesignationId

                LIMIT 1
            ];


            // --------------------------------------------------
            // 2. Make sure Parent Record is a Campaign
            // --------------------------------------------------

            if (defaultDesignation.ParentRecordId == null) {

                System.debug(
                    'No Parent Record found.'
                );

                return;
            }


            if (
                defaultDesignation.ParentRecordId.getSObjectType()
                != Campaign.SObjectType
            ) {

                System.debug(
                    'Parent Record is not a Campaign.'
                );

                return;
            }


            // --------------------------------------------------
            // 3. Get Campaign
            // --------------------------------------------------

            Campaign campaign = [

                SELECT
                    Id,
                    Name,
                    Givebutter_Campaign_ID__c

                FROM Campaign

                WHERE Id = :defaultDesignation.ParentRecordId

                LIMIT 1
            ];


            // --------------------------------------------------
            // 4. Make sure Givebutter Campaign exists
            // --------------------------------------------------

            if (
                String.isBlank(
                    campaign.Givebutter_Campaign_ID__c
                )
            ) {

                System.debug(
                    'Campaign does not have a Givebutter Campaign ID yet.'
                );

                return;
            }


            // --------------------------------------------------
            // 5. Get Gift Designation
            // --------------------------------------------------

            if (defaultDesignation.GiftDesignationId == null) {

                System.debug(
                    'Gift Default Designation has no Gift Designation.'
                );

                return;
            }


            GiftDesignation designation = [

                SELECT
                    Id,
                    Name,
                    Givebutter_Fund_ID__c,
                    Givebutter_Fund_Name__c,
                    Givebutter_Fund_Code__c

                FROM GiftDesignation

                WHERE Id = :defaultDesignation.GiftDesignationId

                LIMIT 1
            ];


            // --------------------------------------------------
            // 6. Prevent duplicate Fund creation
            // --------------------------------------------------

            if (
                !String.isBlank(
                    designation.Givebutter_Fund_ID__c
                )
            ) {

                System.debug(
                    'Givebutter Fund already exists: ' +
                    designation.Givebutter_Fund_ID__c
                );

                return;
            }


            // --------------------------------------------------
            // 7. Determine Fund Name
            // --------------------------------------------------

            String fundName;

            if (
                !String.isBlank(
                    designation.Givebutter_Fund_Name__c
                )
            ) {

                fundName =
                    designation.Givebutter_Fund_Name__c;

            } else {

                fundName =
                    designation.Name;
            }


            // --------------------------------------------------
            // 8. Create Givebutter request body
            // --------------------------------------------------

            Map<String, Object> body =
                new Map<String, Object>();


            body.put(
                'name',
                fundName
            );


            // Add code only when Salesforce has one

            if (
                !String.isBlank(
                    designation.Givebutter_Fund_Code__c
                )
            ) {

                body.put(
                    'code',
                    designation.Givebutter_Fund_Code__c
                );
            }


            // --------------------------------------------------
            // 9. HTTP Request
            // --------------------------------------------------

            HttpRequest req =
                new HttpRequest();


            req.setEndpoint(
                'callout:Givebutter_API/v1/funds'
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


            System.debug(
                'Givebutter Fund Request: ' +
                req.getBody()
            );


            // --------------------------------------------------
            // 10. Send request
            // --------------------------------------------------

            Http http =
                new Http();


            HttpResponse res =
                http.send(req);


            System.debug(
                'Givebutter Fund Status: ' +
                res.getStatusCode()
            );


            System.debug(
                'Givebutter Fund Response: ' +
                res.getBody()
            );


            // --------------------------------------------------
            // 11. Process successful response
            // --------------------------------------------------

            if (
                res.getStatusCode() == 200 ||
                res.getStatusCode() == 201
            ) {

                Map<String, Object> responseBody =
                    (Map<String, Object>)
                    JSON.deserializeUntyped(
                        res.getBody()
                    );


                System.debug(
                    'Parsed Givebutter Response: ' +
                    responseBody
                );


                Object idValue =
                    responseBody.get('id');


                if (idValue == null) {

                    System.debug(
                        'ERROR: Givebutter did not return Fund ID.'
                    );

                    return;
                }


                String givebutterFundId =
                    String.valueOf(idValue);


                System.debug(
                    'Givebutter Fund ID: ' +
                    givebutterFundId
                );


                // --------------------------------------------------
                // 12. Save Givebutter Fund ID to Gift Designation
                // --------------------------------------------------

                GiftDesignation designationToUpdate =
                    new GiftDesignation(

                        Id = designation.Id,

                        Givebutter_Fund_ID__c =
                            givebutterFundId
                    );


                update designationToUpdate;


                System.debug(
                    'SUCCESS: Givebutter Fund ID saved to Gift Designation: ' +
                    givebutterFundId
                );

            } else {

                System.debug(
                    'Givebutter Fund creation failed.'
                );


                System.debug(
                    'Status: ' +
                    res.getStatusCode()
                );


                System.debug(
                    'Response: ' +
                    res.getBody()
                );
            }
        }
    }
}