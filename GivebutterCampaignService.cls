public without sharing class GivebutterCampaignService {

    public static Campaign createOrUpdateCampaign(
        Map<String, Object> data
    ) {

        /*
         * ========================================================
         * 1. VALIDATE DATA
         * ========================================================
         */

        if (data == null) {

            throw new GivebutterCampaignException(
                'Givebutter campaign data is required.'
            );
        }


        /*
         * ========================================================
         * 2. GET GIVEBUTTER CAMPAIGN ID
         * ========================================================
         *
         * campaign.created and campaign.updated use:
         *
         * data.id
         */

        Object campaignIdValue =
            data.get('id');


        if (campaignIdValue == null) {

            throw new GivebutterCampaignException(
                'Givebutter campaign ID is required.'
            );
        }


        String givebutterCampaignId =
            String.valueOf(
                campaignIdValue
            );


        if (
            String.isBlank(
                givebutterCampaignId
            )
        ) {

            throw new GivebutterCampaignException(
                'Givebutter campaign ID is blank.'
            );
        }


        /*
         * ========================================================
         * 3. GET CAMPAIGN INFORMATION
         * ========================================================
         */

        String campaignTitle =
            (String)data.get('title');


        String campaignCode =
            (String)data.get('code');


        String campaignDescription =
            (String)data.get('description');


        /*
         * ========================================================
         * 4. FIND EXISTING CAMPAIGN
         * ========================================================
         */

        List<Campaign> existingCampaigns = [

            SELECT
                Id,
                Name,
                Description,
                Givebutter_Campaign_ID__c,
                Givebutter_Campaign_Code__c

            FROM Campaign

            WHERE Givebutter_Campaign_ID__c =
                :givebutterCampaignId

            WITH SYSTEM_MODE

            LIMIT 1
        ];


        Campaign campaign;


        /*
         * ========================================================
         * 5. EXISTING OR NEW CAMPAIGN
         * ========================================================
         */

        if (!existingCampaigns.isEmpty()) {

            campaign =
                existingCampaigns[0];


            System.debug(
                'Existing Salesforce Campaign found: ' +
                campaign.Id
            );

        } else {

            campaign =
                new Campaign();


            campaign.Givebutter_Campaign_ID__c =
                givebutterCampaignId;


            System.debug(
                'No existing Salesforce Campaign found.'
            );
        }


        /*
         * ========================================================
         * 6. SET CAMPAIGN NAME
         * ========================================================
         */

        if (
            String.isBlank(
                campaignTitle
            )
        ) {

            campaign.Name =
                'Givebutter Campaign ' +
                givebutterCampaignId;

        } else {

            campaign.Name =
                campaignTitle;
        }


        /*
         * ========================================================
         * 7. SET GIVEBUTTER CAMPAIGN CODE
         * ========================================================
         */

        if (
            !String.isBlank(
                campaignCode
            )
        ) {

            campaign.Givebutter_Campaign_Code__c =
                campaignCode;
        }


        /*
         * ========================================================
         * 8. SET DESCRIPTION
         * ========================================================
         */

        if (
            !String.isBlank(
                campaignDescription
            )
        ) {

            campaign.Description =
                campaignDescription;
        }


        /*
         * ========================================================
         * 9. INSERT / UPDATE
         * ========================================================
         */

        if (campaign.Id == null) {

            Database.SaveResult result =
                Database.insert(
                    campaign,
                    false,
                    AccessLevel.SYSTEM_MODE
                );


            if (!result.isSuccess()) {

                String errorMessage =
                    'Unable to create Salesforce Campaign.';


                if (
                    !result.getErrors().isEmpty()
                ) {

                    errorMessage =
                        result.getErrors()[0]
                            .getMessage();
                }


                throw new GivebutterCampaignException(
                    errorMessage
                );
            }


            campaign.Id =
                result.getId();


            System.debug(
                'Created Givebutter Campaign: ' +
                campaign.Id
            );

        } else {

            Database.SaveResult result =
                Database.update(
                    campaign,
                    false,
                    AccessLevel.SYSTEM_MODE
                );


            if (!result.isSuccess()) {

                String errorMessage =
                    'Unable to update Salesforce Campaign.';


                if (
                    !result.getErrors().isEmpty()
                ) {

                    errorMessage =
                        result.getErrors()[0]
                            .getMessage();
                }


                throw new GivebutterCampaignException(
                    errorMessage
                );
            }


            System.debug(
                'Updated Givebutter Campaign: ' +
                campaign.Id
            );
        }


        return campaign;
    }


    public class GivebutterCampaignException
        extends Exception {}
}