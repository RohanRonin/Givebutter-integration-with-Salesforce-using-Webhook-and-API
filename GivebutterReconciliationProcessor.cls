public with sharing class GivebutterReconciliationProcessor {

    public static void reconcile(Date fromDate, Date toDate) {

        if (fromDate == null || toDate == null || fromDate > toDate) {
            throw new IllegalArgumentException(
                'Please provide a valid reconciliation date range.'
            );
        }

        System.debug('===== GIVEBUTTER RECONCILIATION STARTED =====');
        System.debug('From Date: ' + fromDate);
        System.debug('To Date: ' + toDate);

        // 1. Fetch all Givebutter transactions for this date range.
        // This service must handle pagination.
        List<Map<String, Object>> gbTransactions =
            GivebutterTransactionService.getAllTransactions(
                fromDate,
                toDate
            );

        Integer gbCount = gbTransactions.size();
        Decimal gbTotal = 0;

        Map<String, Map<String, Object>> gbMap =
            new Map<String, Map<String, Object>>();

        for (Map<String, Object> gb : gbTransactions) {

            String gbId = getStringValue(gb.get('id'));

            if (String.isBlank(gbId)) {
                continue;
            }

            if (gbMap.containsKey(gbId)) {
                System.debug(
                    'WARNING: Duplicate Givebutter transaction ID: ' + gbId
                );
                continue;
            }

            gbMap.put(gbId, gb);
            gbTotal += getAmount(gb.get('donated'));
        }

        // 2. Retrieve Salesforce Gift Transactions for the same dates.
        List<GiftTransaction> sfTransactions = [
            SELECT Id,
                   Name,
                   Givebutter_Transaction_ID__c,
                   Givebutter_Donated_Amount__c,
                   TransactionDate,
                   Reconciliation_Status__c,
                   Last_Reconciliation_Date__c,
                   Givebutter_Reconciliation__c
            FROM GiftTransaction
            WHERE TransactionDate >= :fromDate
              AND TransactionDate <= :toDate
              AND Givebutter_Transaction_ID__c != null
        ];

        Integer sfCount = sfTransactions.size();
        Decimal sfTotal = 0;

        Map<String, GiftTransaction> sfMap =
            new Map<String, GiftTransaction>();

        for (GiftTransaction sf : sfTransactions) {

            String gbId = sf.Givebutter_Transaction_ID__c;

            if (sfMap.containsKey(gbId)) {
                throw new IllegalArgumentException(
                    'Duplicate Salesforce Gift Transactions found for ' +
                    'Givebutter transaction ID: ' + gbId
                );
            }

            sfMap.put(gbId, sf);

            if (sf.Givebutter_Donated_Amount__c != null) {
                sfTotal += sf.Givebutter_Donated_Amount__c;
            }
        }

        // 3. Compare the records using the Givebutter transaction ID.
        Integer matchedCount = 0;
        Integer mismatchCount = 0;
        Integer missingCount = 0;

        List<String> missingIds = new List<String>();
        List<String> mismatchIds = new List<String>();

        Map<Id, GiftTransaction> updatesById =
            new Map<Id, GiftTransaction>();

        // Clear previous reconciliation links for records in this
        // date range. The current run will relink only its mismatches.
        for (GiftTransaction sf : sfTransactions) {
            sf.Givebutter_Reconciliation__c = null;
            updatesById.put(sf.Id, sf);
        }

        for (String gbId : gbMap.keySet()) {

            Map<String, Object> gb = gbMap.get(gbId);
            Decimal gbAmount = getAmount(gb.get('donated'));

            if (sfMap.containsKey(gbId)) {

                GiftTransaction sf = sfMap.get(gbId);

                Decimal sfAmount =
                    sf.Givebutter_Donated_Amount__c == null
                    ? 0
                    : sf.Givebutter_Donated_Amount__c;

                sf.Last_Reconciliation_Date__c = Date.today();

                if (gbAmount == sfAmount) {

                    matchedCount++;
                    sf.Reconciliation_Status__c = 'Matched';

                    System.debug(
                        'MATCHED: ' + gbId +
                        ' | Givebutter=' + gbAmount +
                        ' | Salesforce=' + sfAmount
                    );

                } else {

                    mismatchCount++;
                    mismatchIds.add(gbId);

                    sf.Reconciliation_Status__c = 'Mismatch';

                    System.debug(
                        'MISMATCH: ' + gbId +
                        ' | Givebutter=' + gbAmount +
                        ' | Salesforce=' + sfAmount
                    );
                }

                updatesById.put(sf.Id, sf);

            } else {

                // Givebutter record exists, but no Salesforce
                // record with this ID was found in the date range.
                missingCount++;
                missingIds.add(gbId);

                System.debug('MISSING IN SALESFORCE: ' + gbId);
            }
        }

        // 4. Calculate the total difference.
        Decimal totalDifference = gbTotal - sfTotal;

        // 5. Create the reconciliation summary first so that
        // its Salesforce record ID is available for the lookup.
        Givebutter_Reconciliation__c reconciliation =
            new Givebutter_Reconciliation__c();

        reconciliation.Run_Date__c = System.now();
        reconciliation.From_Date__c = fromDate;
        reconciliation.To_Date__c = toDate;

        reconciliation.Givebutter_Count__c = gbCount;
        reconciliation.Givebutter_Total__c = gbTotal;

        reconciliation.Salesforce_Count__c = sfCount;
        reconciliation.Salesforce_Total__c = sfTotal;

        reconciliation.Matched_Count__c = matchedCount;
        reconciliation.Missing_Count__c = missingCount;
        reconciliation.Mismatch_Count__c = mismatchCount;

        reconciliation.Corrected_Count__c = 0;
        reconciliation.Error_Count__c = 0;

        if (missingCount == 0 &&
            mismatchCount == 0 &&
            totalDifference == 0) {

            reconciliation.Status__c = 'Completed';

        } else {

            reconciliation.Status__c = 'Completed with Errors';
        }

        List<String> errorMessages = new List<String>();

        if (!missingIds.isEmpty()) {
            errorMessages.add(
                'Missing in Salesforce: ' +
                String.join(missingIds, ', ')
            );
        }

        if (!mismatchIds.isEmpty()) {
            errorMessages.add(
                'Amount mismatches: ' +
                String.join(mismatchIds, ', ')
            );
        }

        if (!errorMessages.isEmpty()) {
            reconciliation.Error_Details__c =
                String.join(errorMessages, '\n');
        }

        insert reconciliation;

        // 6. Link only the mismatched Gift Transactions to this run.
        for (String gbId : mismatchIds) {

            GiftTransaction sf = sfMap.get(gbId);

            if (sf != null) {
                sf.Givebutter_Reconciliation__c =
                    reconciliation.Id;

                updatesById.put(sf.Id, sf);
            }
        }

        // 7. Save statuses, reconciliation dates and lookup links.
        if (!updatesById.isEmpty()) {
            update updatesById.values();
        }

        // 8. Final summary logs.
        System.debug('===== RECONCILIATION RESULT =====');
        System.debug('Reconciliation ID: ' + reconciliation.Id);
        System.debug('Givebutter Count: ' + gbCount);
        System.debug('Givebutter Total: ' + gbTotal);
        System.debug('Salesforce Count: ' + sfCount);
        System.debug('Salesforce Total: ' + sfTotal);
        System.debug('Difference: ' + totalDifference);
        System.debug('Matched: ' + matchedCount);
        System.debug('Mismatch: ' + mismatchCount);
        System.debug('Missing: ' + missingCount);
        System.debug('===== RECONCILIATION FINISHED =====');
    }

    private static Decimal getAmount(Object value) {

        if (value == null ||
            String.isBlank(String.valueOf(value))) {
            return 0;
        }

        return Decimal.valueOf(String.valueOf(value));
    }

    private static String getStringValue(Object value) {

        return value == null ? null : String.valueOf(value);
    }
}