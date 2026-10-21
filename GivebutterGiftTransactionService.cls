public without sharing class GivebutterGiftTransactionService {

    /**
     * Processes a successful Givebutter transaction.
     *
     * Flow:
     *
     * 1. Validate transaction data
     * 2. Check transaction ID
     * 3. Find existing Gift Transaction
     * 4. Find/Create Person Account
     * 5. Find Campaign
     * 6. Create Gift Transaction
     * 7. Create/Update Gift Designation
     * 8. Create/Update Gift Transaction Designation
     * 9. Return Gift Transaction
     */
    public static GiftTransaction process(
        Map<String, Object> data
    ) {

        /*
         * ========================================================
         * 1. VALIDATE DATA
         * ========================================================
         */

        if (data == null) {

            throw new GivebutterGiftTransactionException(
                'Givebutter transaction data is required.'
            );
        }


        /*
         * ========================================================
         * 2. GET GIVEBUTTER TRANSACTION ID
         * ========================================================
         */

        Object transactionIdValue =
            data.get('id');


        if (transactionIdValue == null) {

            throw new GivebutterGiftTransactionException(
                'Givebutter transaction ID is required.'
            );
        }


        String givebutterTransactionId =
            String.valueOf(
                transactionIdValue
            );


        if (
            String.isBlank(
                givebutterTransactionId
            )
        ) {

            throw new GivebutterGiftTransactionException(
                'Givebutter transaction ID is blank.'
            );
        }


        /*
         * ========================================================
         * 3. CHECK EXISTING GIFT TRANSACTION
         * ========================================================
         *
         * Givebutter_Transaction_ID__c is our Givebutter
         * external identifier.
         */

        List<GiftTransaction> existingTransactions = [

            SELECT
                Id,
                Name,
                Givebutter_Transaction_ID__c,
                PaymentIdentifier,
                ProcessorReference,
                DonorId,
                OriginalAmount,
                TransactionDate

            FROM GiftTransaction

            WHERE Givebutter_Transaction_ID__c =
                :givebutterTransactionId

            WITH SYSTEM_MODE

            LIMIT 1
        ];


        /*
         * ========================================================
         * 3A. EXISTING TRANSACTION
         * ========================================================
         *
         * Important:
         *
         * If the transaction already exists, we still check
         * the Gift Designation and Gift Transaction Designation.
         *
         * This allows previously-created transactions to be
         * completed if designation processing failed earlier.
         */

        if (!existingTransactions.isEmpty()) {

            GiftTransaction existingGift =
                existingTransactions[0];


            System.debug(
                'Givebutter Gift Transaction already exists: ' +
                givebutterTransactionId
            );


            /*
             * Get fund_id
             */

            Object existingFundIdValue =
                data.get('fund_id');


            if (
                existingFundIdValue != null
                &&
                !String.isBlank(
                    String.valueOf(
                        existingFundIdValue
                    )
                )
            ) {

                /*
                 * ====================================================
                 * CREATE OR FIND GIFT DESIGNATION
                 * ====================================================
                 */

                GiftDesignation designation =
                    GivebutterGiftDesignationService.createOrUpdateGiftDesignation(data);


                System.debug(
                    'Gift Designation created/found for existing transaction: ' +
                    designation.Id
                );


                /*
                 * ====================================================
                 * CREATE OR UPDATE GIFT TRANSACTION DESIGNATION
                 * ====================================================
                 */

                GivebutterTransactionDesignationService.createOrUpdateDesignation(
                        data,
                        existingGift.Id
                    );


                System.debug(
                    'Gift Transaction Designation created/updated for existing transaction: ' +
                    existingGift.Id
                );
            }


            return existingGift;
        }


        /*
         * ========================================================
         * 4. GET DONOR INFORMATION
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
         * Givebutter transaction payload can contain
         * contact_id.
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


        if (String.isBlank(email)) {

            throw new GivebutterGiftTransactionException(
                'Donor email is required for transaction ' +
                givebutterTransactionId
            );
        }


        /*
         * ========================================================
         * 5. FIND OR CREATE PERSON ACCOUNT
         * ========================================================
         */

        Account donor =
            GivebutterPersonAccountService.findOrCreatePersonAccount(
                    givebutterContactId,
                    firstName,
                    lastName,
                    email,
                    phone
                );


        /*
         * ========================================================
         * 6. GET TRANSACTION AMOUNT
         * ========================================================
         */

        Object amountValue =
            data.get(
                'amount'
            );


        if (amountValue == null) {

            throw new GivebutterGiftTransactionException(
                'Transaction amount is required.'
            );
        }


        Decimal amount =
            Decimal.valueOf(
                String.valueOf(
                    amountValue
                )
            );


        /*
         * ========================================================
         * 7. GET PAYMENT METHOD
         * ========================================================
         */

        String paymentMethod =
            (String)data.get(
                'payment_method'
            );


        if (
            String.isBlank(
                paymentMethod
            )
        ) {

            paymentMethod =
                (String)data.get(
                    'method'
                );
        }


        /*
         * ========================================================
         * 8. GET TRANSACTION STATUS
         * ========================================================
         */

        String transactionStatus =
            (String)data.get(
                'status'
            );


        /*
         * ========================================================
         * 9. GET TRANSACTION NUMBER
         * ========================================================
         */

        String transactionNumber =
            (String)data.get(
                'number'
            );


        /*
         * ========================================================
         * 10. GET CURRENCY
         * ========================================================
         */

        String currencyCode =
            (String)data.get(
                'currency'
            );


        /*
         * ========================================================
         * 11. GET TRANSACTION DATE
         * ========================================================
         */

        String transactionDateText =
            (String)data.get(
                'transacted_at'
            );


        Date transactionDate;


        if (
            !String.isBlank(
                transactionDateText
            )
        ) {

            Datetime transactionDatetime =
                (Datetime)JSON.deserialize(
                    '"' +
                    transactionDateText +
                    '"',
                    Datetime.class
                );


            transactionDate =
                transactionDatetime.date();

        } else {

            transactionDate =
                Date.today();
        }


        /*
         * ========================================================
         * 12. GET FEE
         * ========================================================
         *
         * Givebutter:
         *
         * fee
         *
         * Salesforce:
         *
         * ProcessorTransactionFee
         */

        Decimal processorFee =
            getDecimalValue(
                data,
                'fee'
            );


        /*
         * ========================================================
         * 13. GET FEE COVERED
         * ========================================================
         *
         * Givebutter:
         *
         * fee_covered
         *
         * Salesforce:
         *
         * DonorCoverAmount
         */

        Decimal donorCoverAmount =
            getDecimalValue(
                data,
                'fee_covered'
            );


        /*
         * ========================================================
         * 14. GET DONATED AMOUNT
         * ========================================================
         */

        Decimal donatedAmount =
            getDecimalValue(
                data,
                'donated'
            );


        /*
         * ========================================================
         * 15. GET PAYOUT AMOUNT
         * ========================================================
         */

        Decimal payoutAmount =
            getDecimalValue(
                data,
                'payout'
            );


        /*
         * ========================================================
         * 16. GET FAIR MARKET VALUE
         * ========================================================
         */

        Decimal fairMarketValue =
            getDecimalValue(
                data,
                'fair_market_value_amount'
            );


        /*
         * ========================================================
         * 17. FIND CAMPAIGN
         * ========================================================
         *
         * Transaction payload uses:
         *
         * campaign_id
         */

        Id campaignId;


        Object givebutterCampaignIdValue =
            data.get(
                'campaign_id'
            );


        if (
            givebutterCampaignIdValue != null
        ) {

            String givebutterCampaignId =
                String.valueOf(
                    givebutterCampaignIdValue
                );


            /*
             * Givebutter can send campaign_id = 0
             * when there is no campaign.
             */

            if (
                !String.isBlank(
                    givebutterCampaignId
                )
                &&
                givebutterCampaignId != '0'
            ) {

                List<Campaign> campaigns = [

                    SELECT
                        Id,
                        Name,
                        Givebutter_Campaign_ID__c

                    FROM Campaign

                    WHERE Givebutter_Campaign_ID__c =
                        :givebutterCampaignId

                    WITH SYSTEM_MODE

                    LIMIT 1
                ];


                if (
                    !campaigns.isEmpty()
                ) {

                    campaignId =
                        campaigns[0].Id;
                }
            }
        }


        /*
         * ========================================================
         * 18. CREATE GIFT TRANSACTION
         * ========================================================
         */

        GiftTransaction gift =
            new GiftTransaction();


        /*
         * ========================================================
         * 19. GIFT TRANSACTION NAME
         * ========================================================
         *
         * Format:
         *
         * Donor Name - Amount - Paid Date
         *
         * Example:
         *
         * Jane Doe - 100.00 - 2026-09-23
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


        gift.Name =
            donorName +
            ' - ' +
            amount.setScale(2) +
            ' - ' +
            String.valueOf(
                transactionDate
            );


        /*
         * ========================================================
         * 20. DONOR
         * ========================================================
         */

        gift.DonorId =
            donor.Id;


        /*
         * ========================================================
         * 21. ORIGINAL AMOUNT
         * ========================================================
         */

        gift.OriginalAmount =
            amount;


        /*
         * ========================================================
         * 22. PAYMENT METHOD
         * ========================================================
         */

        if (
            !String.isBlank(
                paymentMethod
            )
        ) {

            gift.PaymentMethod =
                paymentMethod;
        }


        /*
         * ========================================================
         * 23. GIVEBUTTER TRANSACTION ID
         * ========================================================
         */

        gift.Givebutter_Transaction_ID__c =
            givebutterTransactionId;


        /*
         * ========================================================
         * 24. PAYMENT IDENTIFIER
         * ========================================================
         */

        gift.PaymentIdentifier =
            givebutterTransactionId;


        /*
         * ========================================================
         * 25. PROCESSOR REFERENCE
         * ========================================================
         */

        gift.ProcessorReference =
            givebutterTransactionId;


        /*
         * ========================================================
         * 26. GIVEBUTTER TRANSACTION NUMBER
         * ========================================================
         */

        if (
            !String.isBlank(
                transactionNumber
            )
        ) {

            gift.Givebutter_Transaction_Number__c =
                transactionNumber;
        }


        /*
         * ========================================================
         * 27. TRANSACTION DATE
         * ========================================================
         */

        gift.TransactionDate =
            transactionDate;


        /*
         * ========================================================
         * 28. TRANSACTION STATUS
         * ========================================================
         */

        if (
            !String.isBlank(
                transactionStatus
            )
        ) {

            gift.Status =
                transactionStatus;
        }


        /*
         * ========================================================
         * 29. CURRENCY
         * ========================================================
         */

        if (
            !String.isBlank(
                currencyCode
            )
        ) {

            gift.CurrencyIsoCode =
                currencyCode;
        }


        /*
         * ========================================================
         * 30. PROCESSOR TRANSACTION FEE
         * ========================================================
         */

        if (
            processorFee != null
        ) {

            gift.ProcessorTransactionFee =
                processorFee;
        }


        /*
         * ========================================================
         * 31. DONOR COVER AMOUNT
         * ========================================================
         */

        if (
            donorCoverAmount != null
        ) {

            gift.DonorCoverAmount =
                donorCoverAmount;
        }


        /*
         * ========================================================
         * 32. GIVEBUTTER DONATED AMOUNT
         * ========================================================
         */

        if (
            donatedAmount != null
        ) {

            gift.Givebutter_Donated_Amount__c =
                donatedAmount;
        }


        /*
         * ========================================================
         * 33. GIVEBUTTER PAYOUT AMOUNT
         * ========================================================
         */

        if (
            payoutAmount != null
        ) {

            gift.Givebutter_Payout_Amount__c =
                payoutAmount;
        }


        /*
         * ========================================================
         * 34. GIVEBUTTER FAIR MARKET VALUE
         * ========================================================
         */

        if (
            fairMarketValue != null
        ) {

            gift.Givebutter_Fair_Market_Value__c =
                fairMarketValue;
        }


        /*
         * ========================================================
         * 35. CAMPAIGN
         * ========================================================
         */

        if (
            campaignId != null
        ) {

            gift.CampaignId =
                campaignId;
        }


        /*
         * ========================================================
         * 36. CAMPAIGN TITLE
         * ========================================================
         */

        String campaignTitle =
            (String)data.get(
                'campaign_title'
            );


        if (
            !String.isBlank(
                campaignTitle
            )
        ) {

            gift.Description =
                campaignTitle;
        }


        /*
         * ========================================================
         * 37. INSERT GIFT TRANSACTION
         * ========================================================
         */

        Database.SaveResult result =
            Database.insert(
                gift,
                false,
                AccessLevel.SYSTEM_MODE
            );


        if (
            !result.isSuccess()
        ) {

            String errorMessage =
                'Unable to create Gift Transaction.';


            if (
                !result.getErrors().isEmpty()
            ) {

                errorMessage =
                    result.getErrors()[0]
                        .getMessage();
            }


            throw new GivebutterGiftTransactionException(
                errorMessage
            );
        }


        gift.Id =
            result.getId();


        System.debug(
            'Givebutter Gift Transaction created: ' +
            gift.Id
        );


        System.debug(
            'Gift Transaction Name: ' +
            gift.Name
        );


        /*
         * ========================================================
         * 38. CREATE OR FIND GIFT DESIGNATION
         * ========================================================
         *
         * Givebutter transaction:
         *
         * fund_id
         * fund_code
         * fund_name
         *
         * Salesforce:
         *
         * Gift Designation
         *
         * If the Gift Designation already exists for the
         * Givebutter Fund ID, it is updated.
         *
         * If it does not exist, a new Gift Designation
         * is created.
         */

        Object fundIdValue =
            data.get(
                'fund_id'
            );


        if (
            fundIdValue != null
            &&
            !String.isBlank(
                String.valueOf(
                    fundIdValue
                )
            )
        ) {

            GiftDesignation designation =
                GivebutterGiftDesignationService.createOrUpdateGiftDesignation(
                        data
                    );


            System.debug(
                'Gift Designation created/found: ' +
                designation.Id
            );


            /*
             * ====================================================
             * 39. CREATE OR UPDATE GIFT TRANSACTION DESIGNATION
             * ====================================================
             *
             * Connect:
             *
             * Gift Transaction
             *        +
             * Gift Designation
             *
             * Amount = transaction amount
             * Percent = 100%
             */

            GiftTransactionDesignation
                transactionDesignation =
                    GivebutterTransactionDesignationService.createOrUpdateDesignation(
                            data,
                            gift.Id
                        );


            System.debug(
                'Gift Transaction Designation created/updated: ' +
                transactionDesignation.Id
            );
        }


        /*
         * ========================================================
         * 40. RETURN GIFT TRANSACTION
         * ========================================================
         */

        return gift;
    }


    /*
     * ============================================================
     * DECIMAL HELPER
     * ============================================================
     *
     * Safely reads a decimal value from the Givebutter payload.
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
     * CUSTOM EXCEPTION
     * ============================================================
     */

    public class GivebutterGiftTransactionException
        extends Exception {}
}