public class GivebutterReconciliationScheduler
    implements Schedulable {

    public void execute(SchedulableContext sc) {

        System.enqueueJob(new GivebutterReconciliationQueueable());
    }
}