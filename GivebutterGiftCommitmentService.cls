public without sharing class GivebutterGiftCommitmentService {

    /**
     * Creates or updates a Salesforce Gift Commitment
     * from a Givebutter recurring plan event.
     *
     * Supported Givebutter events:
     *
     * plan.created
     * plan.updated
     * plan.paused
     * plan.resumed
     * plan.failed
     * plan.canceled
     */
    public static GiftCommitment createOrUpdateGiftCommitment(
        Map<String, Object> data
    ) {

        /*
         * ========================================================
         * 1. VALIDATE DATA
         * ========================================================
         */

        if (data == null) {

            throw new GivebutterGiftCommitmentException(
                'Givebutter plan data is required.'
            );
        }


        /*
         * ========================================================
         * 2. GET GIVEBUTTER PLAN ID
         * ========================================================
         */

        Object planIdValue =
            data.get('id');


        if (planIdValue == null) {

            throw new GivebutterGiftCommitmentException(
                'Givebutter plan ID is required.'
            );
        }


        String givebutterPlanId =
            String.valueOf(
                planIdValue
            );


        if (
            String.isBlank(
                givebutterPlanId
            )
        ) {

            throw new GivebutterGiftCommitmentException(
                'Givebutter plan ID is blank.'
            );
        }


        /*
         * ========================================================
         * 3. GET DONOR INFORMATION
         * ========================================================
         */

        String firstName =
            (String)data.get(
                'first_name'
            );


        String lastName =
            (String)data.get(
                'last_name'
            );


        String email =
            (String)data.get(
                'email'
            );


        String phone =
            (String)data.get(
                'phone'
            );


        /*
         * Givebutter contact ID.
         */

        String givebutterContactId;


        Object contactIdValue =
            data.get(
                'contact_id'
            );


        if (contactIdValue != null) {

            givebutterContactId =
                String.valueOf(
                    contactIdValue
                );
        }


        /*
         * Email is required because our Person Account
         * matching uses email.
         */

        if (String.isBlank(email)) {

            throw new GivebutterGiftCommitmentException(
                'Donor email is required for Givebutter plan ' +
                givebutterPlanId
            );
        }


        /*
         * ========================================================
         * 4. FIND OR CREATE PERSON ACCOUNT
         * ========================================================
         */

        Account donor =
            GivebutterPersonAccountService.findOrCreatePersonAccount(givebutterContactId,firstName,lastName,email,phone);


        /*
         * ========================================================
         * 5. GET PLAN AMOUNT
         * ========================================================
         */

        Decimal planAmount =
            getDecimalValue(
                data,
                'amount'
            );


        if (planAmount == null) {

            throw new GivebutterGiftCommitmentException(
                'Givebutter plan amount is required.'
            );
        }


        /*
         * ========================================================
         * 6. GET FREQUENCY
         * ========================================================
         */

        String frequency =
            (String)data.get(
                'frequency'
            );


        /*
         * ========================================================
         * 7. GET STATUS
         * ========================================================
         */

        String planStatus =
            (String)data.get(
                'status'
            );


        /*
         * ========================================================
         * 8. GET PAYMENT METHOD
         * ========================================================
         */

        String paymentMethod =
            (String)data.get(
                'method'
            );


        /*
         * ========================================================
         * 9. GET CURRENCY
         * ========================================================
         */

        String currencyCode =
            (String)data.get(
                'currency'
            );


        /*
         * ========================================================
         * 10. GET START DATE
         * ========================================================
         */

        Date startDate =
            parseGivebutterDate(
                data.get('start_at')
            );


        /*
         * ========================================================
         * 11. GET NEXT BILL DATE
         * ========================================================
         */

        Date nextBillDate =
            parseGivebutterDate(
                data.get('next_bill_date')
            );


        /*
         * ========================================================
         * 12. FIND EXISTING GIFT COMMITMENT
         * ========================================================
         *
         * Givebutter_Plan_ID__c is:
         *
         * - External ID
         * - Unique
         */

        List<GiftCommitment> existingCommitments = [

            SELECT
                Id,
                Name,
                DonorId,
                Givebutter_Plan_ID__c,
                NextTransactionAmount,
                NextTransactionDate,
                EffectiveStartDate,
                RecurrenceType,
                Status,
                CurrencyIsoCode,
                Description

            FROM GiftCommitment

            WHERE Givebutter_Plan_ID__c =
                :givebutterPlanId

            WITH SYSTEM_MODE

            LIMIT 1
        ];


        GiftCommitment commitment;


        /*
         * ========================================================
         * 13. EXISTING OR NEW COMMITMENT
         * ========================================================
         */

        if (!existingCommitments.isEmpty()) {

            commitment =
                existingCommitments[0];


            System.debug(
                'Existing Gift Commitment found: ' +
                commitment.Id
            );

        } else {

            commitment =
                new GiftCommitment();


            commitment.Givebutter_Plan_ID__c =
                givebutterPlanId;


            System.debug(
                'No existing Gift Commitment found.'
            );
        }


        /*
         * ========================================================
         * 14. SET DONOR
         * ========================================================
         */

        commitment.DonorId =
            donor.Id;


        /*
         * ========================================================
         * 15. SET NAME
         * ========================================================
         */

        String donorName;


        if (
            !String.isBlank(firstName)
            &&
            !String.isBlank(lastName)
        ) {

            donorName =
                firstName.trim() +
                ' ' +
                lastName.trim();

        } else if (
            !String.isBlank(firstName)
        ) {

            donorName =
                firstName.trim();

        } else if (
            !String.isBlank(lastName)
        ) {

            donorName =
                lastName.trim();

        } else {

            donorName =
                'Givebutter Donor';
        }


        commitment.Name =
            donorName +
            ' - Givebutter Recurring Plan - ' +
            givebutterPlanId;


        /*
         * ========================================================
         * 16. SET NEXT TRANSACTION AMOUNT
         * ========================================================
         */

        commitment.NextTransactionAmount =
            planAmount;


        /*
         * ========================================================
         * 17. SET NEXT TRANSACTION DATE
         * ========================================================
         */

        if (nextBillDate != null) {

            commitment.NextTransactionDate =
                nextBillDate;
        }


        /*
         * ========================================================
         * 18. SET EFFECTIVE START DATE
         * ========================================================
         */

        if (startDate != null) {

            commitment.EffectiveStartDate =
                startDate;
        }


        /*
         * ========================================================
         * 19. SET RECURRENCE TYPE
         * ========================================================
         *
         * Givebutter sends values such as:
         *
         * monthly
         * quarterly
         * yearly
         *
         * We find the corresponding Salesforce picklist
         * value dynamically.
         */

        if (!String.isBlank(frequency)) {

            String recurrenceValue =
                getMatchingPicklistValue(
                    GiftCommitment.RecurrenceType,
                    frequency
                );


            if (
                !String.isBlank(
                    recurrenceValue
                )
            ) {

                commitment.RecurrenceType =
                    recurrenceValue;
            }
        }


        /*
         * ========================================================
         * 20. SET STATUS
         * ========================================================
         *
         * We dynamically look for the matching Salesforce
         * picklist value instead of assuming the exact
         * Salesforce spelling/capitalization.
         */

        if (!String.isBlank(planStatus)) {

            String statusValue =
                getMatchingPicklistValue(
                    GiftCommitment.Status,
                    planStatus
                );


            if (
                !String.isBlank(
                    statusValue
                )
            ) {

                commitment.Status =
                    statusValue;
            }
        }


        /*
         * ========================================================
         * 21. SET CURRENCY
         * ========================================================
         */

        if (
            !String.isBlank(
                currencyCode
            )
        ) {

            commitment.CurrencyIsoCode =
                currencyCode;
        }


        /*
         * ========================================================
         * 22. SET DESCRIPTION
         * ========================================================
         */

        String description =
            'Givebutter recurring plan';


        if (!String.isBlank(frequency)) {

            description +=
                ' - ' +
                frequency;
        }


        if (!String.isBlank(paymentMethod)) {

            description +=
                ' - ' +
                paymentMethod;
        }


        commitment.Description =
            description;


        /*
         * ========================================================
         * 23. INSERT / UPDATE
         * ========================================================
         */

        if (
            commitment.Id == null
        ) {

            Database.SaveResult result =
                Database.insert(
                    commitment,
                    false,
                    AccessLevel.SYSTEM_MODE
                );


            if (!result.isSuccess()) {

                String errorMessage =
                    'Unable to create Gift Commitment.';


                if (
                    !result.getErrors().isEmpty()
                ) {

                    errorMessage =
                        result.getErrors()[0]
                            .getMessage();
                }


                throw new GivebutterGiftCommitmentException(
                    errorMessage
                );
            }


            commitment.Id =
                result.getId();


            System.debug(
                'Created Givebutter Gift Commitment: ' +
                commitment.Id
            );

        } else {

            Database.SaveResult result =
                Database.update(
                    commitment,
                    false,
                    AccessLevel.SYSTEM_MODE
                );


            if (!result.isSuccess()) {

                String errorMessage =
                    'Unable to update Gift Commitment.';


                if (
                    !result.getErrors().isEmpty()
                ) {

                    errorMessage =
                        result.getErrors()[0]
                            .getMessage();
                }


                throw new GivebutterGiftCommitmentException(
                    errorMessage
                );
            }


            System.debug(
                'Updated Givebutter Gift Commitment: ' +
                commitment.Id
            );
        }


        return commitment;
    }


    /*
     * ============================================================
     * DECIMAL HELPER
     * ============================================================
     */

    private static Decimal getDecimalValue(
        Map<String, Object> data,
        String fieldName
    ) {

        Object value =
            data.get(
                fieldName
            );


        if (value == null) {

            return null;
        }


        String valueText =
            String.valueOf(
                value
            );


        if (
            String.isBlank(
                valueText
            )
        ) {

            return null;
        }


        return Decimal.valueOf(
            valueText
        );
    }


    /*
     * ============================================================
     * DATE HELPER
     * ============================================================
     *
     * Givebutter plan dates look like:
     *
     * 2026-03-20 21:03:18
     *
     * They may also be returned as ISO datetime values.
     */

    private static Date parseGivebutterDate(
        Object value
    ) {

        if (value == null) {

            return null;
        }


        String dateText =
            String.valueOf(
                value
            );


        if (
            String.isBlank(
                dateText
            )
        ) {

            return null;
        }


        try {

            /*
             * Convert Givebutter:
             *
             * 2026-03-20 21:03:18
             *
             * into:
             *
             * 2026-03-20T21:03:18
             */

            String normalizedText =
                dateText.replace(
                    ' ',
                    'T'
                );


            /*
             * If there is no timezone,
             * parse the datetime directly.
             */

            if (
                !normalizedText.contains('+')
                &&
                !normalizedText.endsWith('Z')
            ) {

                Datetime dt =
                    Datetime.valueOf(
                        dateText
                    );


                return dt.date();
            }


            Datetime isoDatetime =
                (Datetime)JSON.deserialize(
                    '"' +
                    normalizedText +
                    '"',
                    Datetime.class
                );


            return isoDatetime.date();

        } catch (Exception e) {

            /*
             * Try simple Date parsing as fallback.
             */

            try {

                return Date.valueOf(
                    dateText.substring(
                        0,
                        10
                    )
                );

            } catch (Exception ignored) {

                throw new GivebutterGiftCommitmentException(
                    'Unable to parse Givebutter date: ' +
                    dateText
                );
            }
        }
    }


    /*
     * ============================================================
     * PICKLIST HELPER
     * ============================================================
     *
     * Finds the Salesforce picklist value that matches
     * the Givebutter value without assuming capitalization.
     */

    private static String getMatchingPicklistValue(
        Schema.SObjectField fieldToken,
        String givebutterValue
    ) {

        if (
            fieldToken == null
            ||
            String.isBlank(
                givebutterValue
            )
        ) {

            return null;
        }


        String normalizedGivebutterValue =
            givebutterValue
                .trim()
                .toLowerCase();


        for (
            Schema.PicklistEntry entry :
            fieldToken
                .getDescribe()
                .getPicklistValues()
        ) {

            if (
                entry.getValue()
                    .toLowerCase()
                    ==
                normalizedGivebutterValue
            ) {

                return entry.getValue();
            }


            if (
                entry.getLabel()
                    .toLowerCase()
                    ==
                normalizedGivebutterValue
            ) {

                return entry.getValue();
            }
        }


        return null;
    }


    /*
     * ============================================================
     * CUSTOM EXCEPTION
     * ============================================================
     */

    public class GivebutterGiftCommitmentException
        extends Exception {}
}