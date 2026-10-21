public without sharing class GivebutterPersonAccountService {

    /**
     * Finds an existing Person Account through the
     * Salesforce Duplicate Rule or creates a new one.
     *
     * Matching is controlled by:
     *
     * Givebutter Person Account Email Matching Rule
     * +
     * Givebutter Person Account Email Duplicate Rule
     */
    public static Account findOrCreatePersonAccount(
        String givebutterContactId,
        String firstName,
        String lastName,
        String email,
        String phone
    ) {

        /*
         * ========================================================
         * 1. VALIDATE EMAIL
         * ========================================================
         */

        if (String.isBlank(email)) {

            throw new GivebutterPersonAccountException(
                'Donor email is required.'
            );
        }


        /*
         * Normalize email.
         */

        String normalizedEmail =
            email.trim().toLowerCase();


        /*
         * ========================================================
         * 2. GET PERSON ACCOUNT RECORD TYPE
         * ========================================================
         */

        RecordType personAccountRecordType = [

            SELECT Id

            FROM RecordType

            WHERE SObjectType = 'Account'

            AND IsPersonType = TRUE

            WITH SYSTEM_MODE

            LIMIT 1
        ];


        /*
         * ========================================================
         * 3. PREPARE PERSON ACCOUNT
         * ========================================================
         */

        Account donor =
            new Account();


        donor.RecordTypeId =
            personAccountRecordType.Id;


        /*
         * First Name
         */

        donor.FirstName =
            String.isBlank(firstName)
                ? 'Givebutter'
                : firstName;


        /*
         * Last Name
         */

        donor.LastName =
            String.isBlank(lastName)
                ? 'Donor'
                : lastName;


        /*
         * Email
         */

        donor.PersonEmail =
            normalizedEmail;


        /*
         * Phone
         */

        if (!String.isBlank(phone)) {

            donor.PersonMobilePhone =
                phone;
        }


        /*
         * ========================================================
         * 4. GIVEBUTTER CONTACT ID
         * ========================================================
         *
         * Store the Givebutter contact ID in Salesforce.
         *
         * If the value is not available, we simply don't populate
         * the field.
         */

        if (!String.isBlank(givebutterContactId)) {

            donor.Givebutter_Contact_ID__c =
                givebutterContactId;
        }


        /*
         * ========================================================
         * 5. ENABLE SALESFORCE DUPLICATE RULE
         * ========================================================
         */

        Database.DMLOptions dmlOptions =
            new Database.DMLOptions();


        dmlOptions.DuplicateRuleHeader.allowSave =
            false;


        donor.setOptions(
            dmlOptions
        );


        /*
         * ========================================================
         * 6. INSERT PERSON ACCOUNT
         * ========================================================
         */

        Database.SaveResult result =
            Database.insert(
                donor,
                false,
                AccessLevel.SYSTEM_MODE
            );


        /*
         * ========================================================
         * 7. NEW PERSON ACCOUNT CREATED
         * ========================================================
         */

        if (result.isSuccess()) {

            donor.Id =
                result.getId();


            System.debug(
                'New Givebutter Person Account created: ' +
                donor.Id
            );


            return donor;
        }


        /*
         * ========================================================
         * 8. CHECK DUPLICATE RULE RESULT
         * ========================================================
         */

        for (
            Database.Error error :
            result.getErrors()
        ) {

            if (
                error instanceof Database.DuplicateError
            ) {

                Database.DuplicateError duplicateError =
                    (Database.DuplicateError)error;


                Datacloud.DuplicateResult duplicateResult =
                    duplicateError.getDuplicateResult();


                Set<Id> duplicateIds =
                    getDuplicateRecordIds(
                        duplicateResult
                    );


                /*
                 * =================================================
                 * 9. EXISTING PERSON ACCOUNT FOUND
                 * =================================================
                 */

                if (!duplicateIds.isEmpty()) {

                    Id existingPersonAccountId =
                        duplicateIds.iterator().next();


                    List<Account> existingAccounts = [

                        SELECT
                            Id,
                            FirstName,
                            LastName,
                            PersonEmail,
                            PersonMobilePhone,
                            Givebutter_Contact_ID__c,
                            IsPersonAccount

                        FROM Account

                        WHERE Id =
                            :existingPersonAccountId

                        WITH SYSTEM_MODE

                        LIMIT 1
                    ];


                    if (!existingAccounts.isEmpty()) {

                        Account existingDonor =
                            existingAccounts[0];


                        System.debug(
                            'Existing Givebutter Person Account found through Duplicate Rule: ' +
                            existingDonor.Id
                        );


                        /*
                         * If the existing donor does not have
                         * the Givebutter Contact ID, populate it.
                         *
                         * This is useful when the donor already
                         * existed in Salesforce before integration.
                         */

                        if (
                            String.isBlank(
                                existingDonor.Givebutter_Contact_ID__c
                            )
                            &&
                            !String.isBlank(
                                givebutterContactId
                            )
                        ) {

                            existingDonor.Givebutter_Contact_ID__c =
                                givebutterContactId;


                            Database.update(
                                existingDonor,
                                false,
                                AccessLevel.SYSTEM_MODE
                            );
                        }


                        return existingDonor;
                    }
                }
            }
        }


        /*
         * ========================================================
         * 10. OTHER SALESFORCE ERROR
         * ========================================================
         */

        String errorMessage =
            'Unable to create Person Account.';


        if (!result.getErrors().isEmpty()) {

            errorMessage =
                result.getErrors()[0].getMessage();
        }


        throw new GivebutterPersonAccountException(
            errorMessage
        );
    }


    /**
     * Extract matching Account IDs from
     * Salesforce Duplicate Management.
     */
    private static Set<Id> getDuplicateRecordIds(
        Datacloud.DuplicateResult duplicateResult
    ) {

        Set<Id> duplicateIds =
            new Set<Id>();


        if (duplicateResult == null) {

            return duplicateIds;
        }


        for (
            Datacloud.MatchResult matchResult :
            duplicateResult.getMatchResults()
        ) {

            for (
                Datacloud.MatchRecord matchRecord :
                matchResult.getMatchRecords()
            ) {

                SObject duplicateRecord =
                    matchRecord.getRecord();


                if (
                    duplicateRecord != null &&
                    duplicateRecord.Id != null
                ) {

                    duplicateIds.add(
                        duplicateRecord.Id
                    );
                }
            }
        }


        return duplicateIds;
    }


    /**
     * Custom exception.
     */
    public class GivebutterPersonAccountException
        extends Exception {}
}