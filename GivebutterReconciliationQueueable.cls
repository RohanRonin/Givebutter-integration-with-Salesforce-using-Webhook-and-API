public class GivebutterReconciliationQueueable
    implements Queueable, Database.AllowsCallouts {

    private Date fromDate;
    private Date toDate;

    // Default: reconcile today's transactions.
    public GivebutterReconciliationQueueable() {
        this.fromDate = Date.today();
        this.toDate = Date.today();
    }

    // Custom date range.
    public GivebutterReconciliationQueueable(
        Date fromDate,
        Date toDate
    ) {
        this.fromDate = fromDate;
        this.toDate = toDate;
    }

    public void execute(QueueableContext context) {

        System.debug(
            '===== GIVEBUTTER QUEUEABLE STARTED ====='
        );

        System.debug('From Date: ' + fromDate);
        System.debug('To Date: ' + toDate);

        GivebutterReconciliationProcessor.reconcile(
            fromDate,
            toDate
        );

        System.debug(
            '===== GIVEBUTTER QUEUEABLE FINISHED ====='
        );
    }
}