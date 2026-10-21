global without sharing class GivebutterRetryScheduler implements Schedulable {

    private static final Integer SCHEDULE_INTERVAL_MINUTES = 5;
    private static final String JOB_PREFIX = 'Givebutter Retry Scheduler';

    global void execute(SchedulableContext context) {

        List<Givebutter_Event_Staging__c> dueRecords = [
            SELECT Id,
                   Status__c,
                   Retry_Count__c,
                   Next_Retry_At__c
            FROM Givebutter_Event_Staging__c
            WHERE Status__c = 'Retry Pending'
              AND Next_Retry_At__c <= :System.now()
            LIMIT 1
            FOR UPDATE
        ];

        if (!dueRecords.isEmpty()) {

            Givebutter_Event_Staging__c staging = dueRecords[0];

            staging.Status__c = 'Processing';

            Database.SaveResult result = Database.update(
                staging,
                false,
                AccessLevel.SYSTEM_MODE
            );

            if (result.isSuccess()) {

                System.enqueueJob(
                    new GivebutterWebhook.GivebutterEventProcessor(
                        staging.Id
                    )
                );

                System.debug(
                    'Givebutter retry queued: ' + staging.Id
                );

            } else {

                System.debug(
                    'Failed to mark retry record as Processing: '
                    + result.getErrors()[0].getMessage()
                );
            }
        }

        // Schedule the next execution
        scheduleNextRun();
    }


    private static void scheduleNextRun() {

        Datetime nextRun =
            System.now().addMinutes(SCHEDULE_INTERVAL_MINUTES);

        String cronExpression =
            String.valueOf(nextRun.second()) + ' ' +
            String.valueOf(nextRun.minute()) + ' ' +
            String.valueOf(nextRun.hour()) + ' ' +
            String.valueOf(nextRun.day()) + ' ' +
            String.valueOf(nextRun.month()) + ' ? ' +
            String.valueOf(nextRun.year());

        String jobName =
            JOB_PREFIX + ' ' + String.valueOf(nextRun.getTime());

        System.schedule(
            jobName,
            cronExpression,
            new GivebutterRetryScheduler()
        );

        System.debug(
            'Next Givebutter retry scheduler: ' +
            nextRun
        );
    }
}