public without sharing class GivebutterGiftCommitmentScheduleService {
    
    public static Id createOrUpdateGiftCommitmentSchedule(
        Map<String, Object> data,
        Id giftCommitmentId
    ) {
        
        if (data == null) {
            throw new GivebutterGiftCommitmentScheduleException(
                'Givebutter plan data is required.'
            );
        }
        
        if (giftCommitmentId == null) {
            throw new GivebutterGiftCommitmentScheduleException(
                'Gift Commitment Id is required.'
            );
        }
        
        // ---------------------------------------------------------
        // 1. Read Givebutter values
        // ---------------------------------------------------------
        
        String planId = (String) data.get('id');
        
        if (String.isBlank(planId)) {
            throw new GivebutterGiftCommitmentScheduleException(
                'Givebutter plan id is required.'
            );
        }
        
        Decimal amount = getDecimalValue(data.get('amount'));
        
        if (amount == null) {
            throw new GivebutterGiftCommitmentScheduleException(
                'Givebutter plan amount is required.'
            );
        }
        
        String frequency =
            data.get('frequency') == null
            ? null
            : String.valueOf(data.get('frequency'));
        
        String paymentMethod =
            data.get('method') == null
            ? null
            : String.valueOf(data.get('method'));
        
        Date startDate = parseGivebutterDate(data.get('start_at'));
        
        if (startDate == null) {
            throw new GivebutterGiftCommitmentScheduleException(
                'Givebutter start_at is required.'
            );
        }
        
        Date endDate = parseGivebutterDate(data.get('canceled_at'));
        
        Date nextBillDate =
            parseGivebutterDate(data.get('next_bill_date'));
        
        // ---------------------------------------------------------
        // 2. Build the Gift Commitment Schedule input
        //
        // IMPORTANT:
        // We do NOT reference GiftCommitmentSchedule directly.
        // Salesforce's standard action accepts the schedule data.
        // ---------------------------------------------------------
        
        Map<String, Object> schedule =
            new Map<String, Object>();
        
        schedule.put(
            'GiftCommitmentId',
            String.valueOf(giftCommitmentId)
        );
        
        schedule.put(
            'StartDate',
            startDate
        );
        
        schedule.put(
            'TransactionAmount',
            amount
        );
        
        // Givebutter plan ID is stored on our custom field.
        schedule.put(
            'Givebutter_Plan_ID__c',
            planId
        );
        
        // ---------------------------------------------------------
        // 3. Transaction interval / period
        // ---------------------------------------------------------
        
        if (String.isNotBlank(frequency)) {
            
            String normalizedFrequency =
                frequency.trim().toLowerCase();
            
            if (normalizedFrequency == 'monthly') {
                
                schedule.put('TransactionInterval', 1);
                schedule.put('TransactionPeriod', 'Monthly');
                
            } else if (normalizedFrequency == 'quarterly') {
                
                schedule.put('TransactionInterval', 3);
                schedule.put('TransactionPeriod', 'Monthly');
                
            } else if (
                normalizedFrequency == 'yearly' ||
                normalizedFrequency == 'annual' ||
                normalizedFrequency == 'annually'
            ) {
                
                schedule.put('TransactionInterval', 1);
                schedule.put('TransactionPeriod', 'Yearly');
                
            } else {
                
                schedule.put(
                    'TransactionPeriod',
                    getMatchingPicklistValue(
                        'GiftCommitmentSchedule',
                        'TransactionPeriod',
                        frequency
                    )
                );
                
                schedule.put(
                    'TransactionInterval',
                    1
                );
            }
        }
        
        // ---------------------------------------------------------
        // 4. Transaction day
        // ---------------------------------------------------------
        if (nextBillDate != null) {
            
            schedule.put(
                'TransactionDay',
                String.valueOf(nextBillDate.day())
            );
            
        } else {
            
            schedule.put(
                'TransactionDay',
                String.valueOf(startDate.day())
            );
        }
        // ---------------------------------------------------------
        // 5. Payment method
        // ---------------------------------------------------------
        
        if (String.isNotBlank(paymentMethod)) {
            
            String matchingPaymentMethod =
                getMatchingPicklistValue(
                    'GiftCommitmentSchedule',
                    'PaymentMethod',
                    paymentMethod
                );
            
            if (matchingPaymentMethod != null) {
                
                schedule.put(
                    'PaymentMethod',
                    matchingPaymentMethod
                );
            }
        }
        
        // ---------------------------------------------------------
        // 6. End date
        // ---------------------------------------------------------
        
        if (endDate != null) {
            
            schedule.put(
                'EndDate',
                endDate
            );
        }
        
        // ---------------------------------------------------------
        // 7. Call Salesforce standard action
        //
        // manageRcrGiftCmtSchd
        // ---------------------------------------------------------
        
        Invocable.Action action =
            Invocable.Action.createStandardAction(
                'manageRcrGiftCmtSchd'
            );
        
        action.setInvocationParameter(
            'giftCommitmentSchedule',
            schedule
        );
        
        List<Invocable.Action.Result> results =
            action.invoke();
        
        // ---------------------------------------------------------
        // 8. Validate action result
        // ---------------------------------------------------------
        
        if (results == null || results.isEmpty()) {
            
            throw new GivebutterGiftCommitmentScheduleException(
                'Salesforce returned no result from manageRcrGiftCmtSchd.'
            );
        }
        
        Invocable.Action.Result result =
            results[0];
        
        if (!result.isSuccess()) {
            
            String errorMessage =
                'Unknown Salesforce action error.';
            
            List<Invocable.Action.Error> errors =
                result.getErrors();
            
            if (errors != null && !errors.isEmpty()) {
                
                List<String> messages =
                    new List<String>();
                
                for (Invocable.Action.Error error : errors) {
                    
                    messages.add(
                        error.getMessage()
                    );
                }
                
                errorMessage =
                    String.join(messages, ' | ');
            }
            
            throw new GivebutterGiftCommitmentScheduleException(
                'Failed to create Gift Commitment Schedule: '
                + errorMessage
            );
        }
        
        // ---------------------------------------------------------
        // 9. Get created/updated schedule ID
        // ---------------------------------------------------------
        
        Map<String, Object> outputValues =
            result.getOutputParameters();
        
        if (outputValues == null) {
            return null;
        }
        
        Object scheduleIds =
            outputValues.get(
                'giftCommitmentScheduleIdsList'
            );
        
        if (scheduleIds == null) {
            return null;
        }
        
        if (scheduleIds instanceof List<Object>) {
            
            List<Object> ids =
                (List<Object>) scheduleIds;
            
            if (!ids.isEmpty()) {
                
                return (Id) ids[0];
            }
        }
        
        if (scheduleIds instanceof List<String>) {
            
            List<String> ids =
                (List<String>) scheduleIds;
            
            if (!ids.isEmpty()) {
                
                return (Id) ids[0];
            }
        }
        
        return null;
    }
    
    
    // =============================================================
    // Decimal helper
    // =============================================================
    
    private static Decimal getDecimalValue(Object value) {
        
        if (value == null) {
            return null;
        }
        
        if (value instanceof Decimal) {
            return (Decimal) value;
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
    // Givebutter Date helper
    //
    // Example:
    // 2026-09-30 07:27:14
    // =============================================================
    
    private static Date parseGivebutterDate(Object value) {
        
        if (value == null) {
            return null;
        }
        
        String dateTimeValue =
            String.valueOf(value).trim();
        
        if (String.isBlank(dateTimeValue)) {
            return null;
        }
        
        try {
            
            String datePart =
                dateTimeValue.contains(' ')
                ? dateTimeValue.substringBefore(' ')
                : dateTimeValue;
            
            List<String> parts =
                datePart.split('-');
            
            if (parts.size() != 3) {
                return null;
            }
            
            return Date.newInstance(
                Integer.valueOf(parts[0]),
                Integer.valueOf(parts[1]),
                Integer.valueOf(parts[2])
            );
            
        } catch (Exception e) {
            
            throw new GivebutterGiftCommitmentScheduleException(
                'Unable to parse Givebutter date: '
                + dateTimeValue
            );
        }
    }
    
    
    // =============================================================
    // Picklist helper
    //
    // Uses the actual Salesforce picklist value where possible.
    // =============================================================
    
    private static String getMatchingPicklistValue(
        String objectName,
        String fieldName,
        String incomingValue
    ) {
        
        if (String.isBlank(incomingValue)) {
            return null;
        }
        
        Map<String, Schema.SObjectType> globalDescribe =
            Schema.getGlobalDescribe();
        
        if (!globalDescribe.containsKey(objectName)) {
            return incomingValue;
        }
        
        Schema.DescribeSObjectResult objectDescribe =
            globalDescribe.get(objectName).getDescribe();
        
        Schema.SObjectField field =
            objectDescribe.fields.getMap().get(fieldName);
        
        if (field == null) {
            return incomingValue;
        }
        
        Schema.DescribeFieldResult fieldDescribe =
            field.getDescribe();
        
        if (fieldDescribe.getType() != Schema.DisplayType.Picklist) {
            return incomingValue;
        }
        
        String normalizedIncoming =
            incomingValue.trim().toLowerCase();
        
        for (
            Schema.PicklistEntry entry :
            fieldDescribe.getPicklistValues()
        ) {
            
            if (!entry.isActive()) {
                continue;
            }
            
            if (
                entry.getValue().trim().toLowerCase()
                == normalizedIncoming
            ) {
                return entry.getValue();
            }
        }
        
        // Common Givebutter → Salesforce mappings
        
        if (fieldName == 'TransactionPeriod') {
            
            if (normalizedIncoming == 'monthly') {
                
                return findPicklistValue(
                    fieldDescribe,
                    new Set<String>{
                        'monthly',
                            'month'
                            }
                );
            }
            
            if (normalizedIncoming == 'yearly') {
                
                return findPicklistValue(
                    fieldDescribe,
                    new Set<String>{
                        'yearly',
                            'year',
                            'annual',
                            'annually'
                            }
                );
            }
        }
        
        if (fieldName == 'PaymentMethod') {
            
            if (normalizedIncoming == 'card') {
                
                return findPicklistValue(
                    fieldDescribe,
                    new Set<String>{
                        'card',
                            'credit card',
                            'creditcard'
                            }
                );
            }
        }
        
        return null;
    }
    
    
    private static String findPicklistValue(
        Schema.DescribeFieldResult fieldDescribe,
        Set<String> possibleValues
    ) {
        
        for (
            Schema.PicklistEntry entry :
            fieldDescribe.getPicklistValues()
        ) {
            
            if (!entry.isActive()) {
                continue;
            }
            
            if (
                possibleValues.contains(
                    entry.getValue().trim().toLowerCase()
                )
            ) {
                return entry.getValue();
            }
        }
        
        return null;
    }
    
    
    // =============================================================
    // Exception
    // =============================================================
    
    public class GivebutterGiftCommitmentScheduleException
        extends Exception {}
}