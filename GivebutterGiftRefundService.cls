public without sharing class GivebutterGiftRefundService {

    public static SObject createOrUpdateGiftRefund(
        Map<String, Object> data
    ) {

        // ---------------------------------------------------------
        // 1. Validate input
        // ---------------------------------------------------------

        if (data == null) {
            throw new GivebutterGiftRefundException(
                'Givebutter refund data is required.'
            );
        }

        // ---------------------------------------------------------
        // 2. Get GiftRefund dynamically
        // ---------------------------------------------------------

        Schema.SObjectType giftRefundType =
            Schema.getGlobalDescribe().get('GiftRefund');

        if (giftRefundType == null) {
            throw new GivebutterGiftRefundException(
                'GiftRefund object is not available.'
            );
        }

        Schema.DescribeSObjectResult refundDescribe =
            giftRefundType.getDescribe();

        if (!refundDescribe.isQueryable()) {
            throw new GivebutterGiftRefundException(
                'GiftRefund object is not queryable.'
            );
        }

        // ---------------------------------------------------------
        // 3. Givebutter Refund ID
        // ---------------------------------------------------------

        String refundId =
            getStringValue(data, 'id');

        if (String.isBlank(refundId)) {
            throw new GivebutterGiftRefundException(
                'Givebutter Refund ID is required.'
            );
        }

        // ---------------------------------------------------------
        // 4. Transaction ID
        // ---------------------------------------------------------

        String transactionId =
            getStringValue(data, 'transaction_id');

        if (String.isBlank(transactionId)) {
            throw new GivebutterGiftRefundException(
                'Givebutter Transaction ID is required.'
            );
        }

        // ---------------------------------------------------------
        // 5. Check existing Gift Refund dynamically
        // ---------------------------------------------------------

        String escapedRefundId =
            String.escapeSingleQuotes(refundId);

        String refundQuery =
            'SELECT ' +
            'Id, ' +
            'GiftTransactionId, ' +
            'Givebutter_Refund_ID__c, ' +
            'Givebutter_Transaction_ID__c, ' +
            'Givebutter_Refund_Amount__c, ' +
            'Amount, ' +
            'Date, ' +
            'Reason, ' +
            'Status ' +
            'FROM GiftRefund ' +
            'WHERE Givebutter_Refund_ID__c = \'' +
            escapedRefundId +
            '\' ' +
            'LIMIT 1';

        List<SObject> existingRefunds =
            Database.query(
                refundQuery,
                AccessLevel.SYSTEM_MODE
            );

        SObject refund;

        if (existingRefunds.isEmpty()) {

            refund =
                giftRefundType.newSObject();

        } else {

            refund =
                existingRefunds[0];
        }

        // ---------------------------------------------------------
        // 6. Find Gift Transaction
        // ---------------------------------------------------------

 List<GiftTransaction> transactions = [
    SELECT
        Id,
        Givebutter_Transaction_ID__c,
        IsPartiallyRefunded,
        RefundedAmount
    FROM GiftTransaction
    WHERE Givebutter_Transaction_ID__c = :transactionId
    WITH SYSTEM_MODE
    LIMIT 1
 ];

        if (transactions.isEmpty()) {
            throw new GivebutterGiftRefundException(
                'Gift Transaction was not found for Givebutter Transaction ID: '
                + transactionId
            );
        }

        GiftTransaction giftTransaction =
            transactions[0];

        // ---------------------------------------------------------
        // 7. Read refund values
        // ---------------------------------------------------------

        Decimal refundAmount =
            getDecimalValue(data, 'amount');

        String status =
            getStringValue(data, 'status');

        String reason =
            getStringValue(data, 'reason');

        String createdAt =
            getStringValue(data, 'created_at');

        Date refundDate =
            parseGivebutterDate(createdAt);

        // ---------------------------------------------------------
        // 8. Link Gift Transaction
        // ---------------------------------------------------------

        refund.put(
            'GiftTransactionId',
            giftTransaction.Id
        );

        // ---------------------------------------------------------
        // 9. Givebutter Refund ID
        // ---------------------------------------------------------

        refund.put(
            'Givebutter_Refund_ID__c',
            refundId
        );

        // ---------------------------------------------------------
        // 10. Givebutter Transaction ID
        // ---------------------------------------------------------

        refund.put(
            'Givebutter_Transaction_ID__c',
            transactionId
        );

        // ---------------------------------------------------------
        // 11. Refund Amount
        // ---------------------------------------------------------

        if (refundAmount != null) {

            refund.put(
                'Amount',
                refundAmount
            );

            refund.put(
                'Givebutter_Refund_Amount__c',
                refundAmount
            );
        }

        // ---------------------------------------------------------
        // 12. Refund Date
        // ---------------------------------------------------------

        if (refundDate != null) {

            refund.put(
                'Date',
                refundDate
            );
        }

        // ---------------------------------------------------------
        // 13. Refund Reason
        // ---------------------------------------------------------

        if (!String.isBlank(reason)) {

            Schema.SObjectField reasonField =
                giftRefundType
                    .getDescribe()
                    .fields
                    .getMap()
                    .get('Reason');

            if (reasonField != null) {

                String matchingReason =
                    getMatchingPicklistValue(
                        reasonField,
                        reason
                    );

                if (matchingReason != null) {

                    refund.put(
                        'Reason',
                        matchingReason
                    );
                }
            }
        }

        // ---------------------------------------------------------
        // 14. Refund Status
        // ---------------------------------------------------------

        if (!String.isBlank(status)) {

            Schema.SObjectField statusField =
                giftRefundType
                    .getDescribe()
                    .fields
                    .getMap()
                    .get('Status');

            if (statusField != null) {

                String matchingStatus =
                    getMatchingPicklistValue(
                        statusField,
                        status
                    );

                if (matchingStatus != null) {

                    refund.put(
                        'Status',
                        matchingStatus
                    );
                }
            }
        }

        // ---------------------------------------------------------
        // 15. Insert / Update dynamically
        // ---------------------------------------------------------

        if (refund.get('Id') == null) {

            Database.SaveResult insertResult =
                Database.insert(
                    refund,
                    false,
                    AccessLevel.SYSTEM_MODE
                );

            if (!insertResult.isSuccess()) {

                throw new GivebutterGiftRefundException(
                    'Failed to create Gift Refund: '
                    + getDatabaseErrorMessage(
                        insertResult.getErrors()
                    )
                );
            }

        } else {

            Database.SaveResult updateResult =
                Database.update(
                    refund,
                    false,
                    AccessLevel.SYSTEM_MODE
                );

            if (!updateResult.isSuccess()) {

                throw new GivebutterGiftRefundException(
                    'Failed to update Gift Refund: '
                    + getDatabaseErrorMessage(
                        updateResult.getErrors()
                    )
                );
            }
        }

        return refund;
    }

    // =============================================================
    // Helper: String
    // =============================================================

    private static String getStringValue(
        Map<String, Object> data,
        String fieldName
    ) {

        Object value = data.get(fieldName);

        if (value == null) {
            return null;
        }

        String result =
            String.valueOf(value);

        if (result == 'null') {
            return null;
        }

        return result;
    }

    // =============================================================
    // Helper: Decimal
    // =============================================================

    private static Decimal getDecimalValue(
        Map<String, Object> data,
        String fieldName
    ) {

        Object value = data.get(fieldName);

        if (value == null) {
            return null;
        }

        if (value instanceof Decimal) {
            return (Decimal)value;
        }

        if (value instanceof Integer) {
            return Decimal.valueOf(
                String.valueOf(value)
            );
        }

        if (value instanceof Long) {
            return Decimal.valueOf(
                String.valueOf(value)
            );
        }

        if (value instanceof Double) {
            return Decimal.valueOf(
                String.valueOf(value)
            );
        }

        return Decimal.valueOf(
            String.valueOf(value)
        );
    }

    // =============================================================
    // Helper: Date Parser
    // =============================================================

    private static Date parseGivebutterDate(
        String value
    ) {

        if (String.isBlank(value)) {
            return null;
        }

        try {

            // YYYY-MM-DD
            if (value.length() == 10) {
                return Date.valueOf(value);
            }

            // YYYY-MM-DD HH:mm:ss
            if (
                value.length() >= 19 &&
                value.substring(10, 11) == ' '
            ) {

                return Date.valueOf(
                    value.substring(0, 10)
                );
            }

            // YYYY-MM-DDTHH:mm:ss...
            if (value.contains('T')) {

                return Date.valueOf(
                    value.substring(0, 10)
                );
            }

        } catch (Exception e) {

            throw new GivebutterGiftRefundException(
                'Unable to parse Givebutter refund date: '
                + value
            );
        }

        return null;
    }

    // =============================================================
    // Helper: Picklist Matching
    // =============================================================

    private static String getMatchingPicklistValue(
        Schema.SObjectField fieldToken,
        String givebutterValue
    ) {

        if (String.isBlank(givebutterValue)) {
            return null;
        }

        String normalizedGivebutterValue =
            givebutterValue.trim().toLowerCase();

        for (
            Schema.PicklistEntry entry :
            fieldToken.getDescribe().getPicklistValues()
        ) {

            if (!entry.isActive()) {
                continue;
            }

            String salesforceValue =
                entry.getValue();

            // Match API value
            if (
                salesforceValue.toLowerCase()
                    == normalizedGivebutterValue
            ) {

                return salesforceValue;
            }

            // Match label
            if (
                entry.getLabel().toLowerCase()
                    == normalizedGivebutterValue
            ) {

                return salesforceValue;
            }
        }

        return null;
    }

    // =============================================================
    // Helper: Database Error
    // =============================================================

    private static String getDatabaseErrorMessage(
        Database.Error[] errors
    ) {

        if (errors == null || errors.isEmpty()) {
            return 'Unknown database error.';
        }

        String message = '';

        for (Database.Error error : errors) {

            if (!String.isBlank(message)) {
                message += ' | ';
            }

            message += error.getStatusCode()
                + ': '
                + error.getMessage();
        }

        return message;
    }

    // =============================================================
    // Exception
    // =============================================================

    public class GivebutterGiftRefundException
        extends Exception {}
}