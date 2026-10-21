public without sharing class GivebutterGiftDesignationService {

    public static GiftDesignation createOrUpdateGiftDesignation(
        Map<String, Object> data
    ) {

        /*
         * ========================================================
         * 1. VALIDATE DATA
         * ========================================================
         */

        if (data == null) {

            throw new GivebutterGiftDesignationException(
                'Givebutter fund data is required.'
            );
        }


        /*
         * ========================================================
         * 2. GET GIVEBUTTER FUND ID
         * ========================================================
         *
         * fund_id is our unique identifier.
         *
         * Salesforce field:
         *
         * Givebutter_Fund_ID__c
         */

        Object fundIdValue =
            data.get('fund_id');


        if (fundIdValue == null) {

            throw new GivebutterGiftDesignationException(
                'Givebutter fund ID is required.'
            );
        }


        String givebutterFundId =
            String.valueOf(
                fundIdValue
            );


        if (
            String.isBlank(
                givebutterFundId
            )
        ) {

            throw new GivebutterGiftDesignationException(
                'Givebutter fund ID is blank.'
            );
        }


        /*
         * ========================================================
         * 3. GET FUND INFORMATION
         * ========================================================
         */

        String fundCode =
            (String)data.get('fund_code');


        String fundName =
            (String)data.get('fund_name');


        /*
         * ========================================================
         * 4. FIND EXISTING GIFT DESIGNATION
         * ========================================================
         *
         * We use Givebutter_Fund_ID__c because it is:
         *
         * - External ID
         * - Unique
         *
         * This prevents duplicate Gift Designations.
         */

        List<GiftDesignation> existingDesignations = [

            SELECT
                Id,
                Name,
                IsActive,
                Description,
                Givebutter_Fund_ID__c,
                Givebutter_Fund_Code__c,
                Givebutter_Fund_Name__c

            FROM GiftDesignation

            WHERE Givebutter_Fund_ID__c =
                :givebutterFundId

            WITH SYSTEM_MODE

            LIMIT 1
        ];


        GiftDesignation designation;


        /*
         * ========================================================
         * 5. EXISTING OR NEW GIFT DESIGNATION
         * ========================================================
         */

        if (!existingDesignations.isEmpty()) {

            designation =
                existingDesignations[0];


            System.debug(
                'Existing Gift Designation found: ' +
                designation.Id
            );

        } else {

            designation =
                new GiftDesignation();


            designation.Givebutter_Fund_ID__c =
                givebutterFundId;


            System.debug(
                'No existing Gift Designation found.'
            );
        }


        /*
         * ========================================================
         * 6. SET GIFT DESIGNATION NAME
         * ========================================================
         *
         * Prefer Givebutter fund name.
         *
         * If fund name is unavailable, use fund code.
         *
         * If both are unavailable, use the Givebutter ID.
         */

        if (!String.isBlank(fundName)) {

            designation.Name =
                fundName;

        } else if (!String.isBlank(fundCode)) {

            designation.Name =
                fundCode;

        } else {

            designation.Name =
                'Givebutter Fund ' +
                givebutterFundId;
        }


        /*
         * ========================================================
         * 7. SET GIVEBUTTER FUND CODE
         * ========================================================
         */

        if (!String.isBlank(fundCode)) {

            designation.Givebutter_Fund_Code__c =
                fundCode;
        }


        /*
         * ========================================================
         * 8. SET GIVEBUTTER FUND NAME
         * ========================================================
         */

        if (!String.isBlank(fundName)) {

            designation.Givebutter_Fund_Name__c =
                fundName;
        }


        /*
         * ========================================================
         * 9. ACTIVATE DESIGNATION
         * ========================================================
         */

        designation.IsActive = true;


        /*
         * ========================================================
         * 10. INSERT / UPDATE
         * ========================================================
         */

        if (designation.Id == null) {

            Database.SaveResult result =
                Database.insert(
                    designation,
                    false,
                    AccessLevel.SYSTEM_MODE
                );


            if (!result.isSuccess()) {

                String errorMessage =
                    'Unable to create Gift Designation.';


                if (
                    !result.getErrors().isEmpty()
                ) {

                    errorMessage =
                        result.getErrors()[0]
                            .getMessage();
                }


                throw new GivebutterGiftDesignationException(
                    errorMessage
                );
            }


            designation.Id =
                result.getId();


            System.debug(
                'Created Givebutter Gift Designation: ' +
                designation.Id
            );

        } else {

            Database.SaveResult result =
                Database.update(
                    designation,
                    false,
                    AccessLevel.SYSTEM_MODE
                );


            if (!result.isSuccess()) {

                String errorMessage =
                    'Unable to update Gift Designation.';


                if (
                    !result.getErrors().isEmpty()
                ) {

                    errorMessage =
                        result.getErrors()[0]
                            .getMessage();
                }


                throw new GivebutterGiftDesignationException(
                    errorMessage
                );
            }


            System.debug(
                'Updated Givebutter Gift Designation: ' +
                designation.Id
            );
        }


        return designation;
    }


    /*
     * ============================================================
     * CUSTOM EXCEPTION
     * ============================================================
     */

    public class GivebutterGiftDesignationException
        extends Exception {}
}