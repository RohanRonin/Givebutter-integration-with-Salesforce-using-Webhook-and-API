public with sharing class GivebutterReconciliationService {

    public static String getTransactions(Datetime fromDate,Datetime toDate) {

        HttpRequest req = new HttpRequest();

        String endpoint = 'callout:Givebutter_API/v1/transactions' + '?transactedAfter=' +
            EncodingUtil.urlEncode(fromDate.formatGMT('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),'UTF-8') +
            '&transactedBefore=' +
            EncodingUtil.urlEncode(
                toDate.formatGMT('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
                'UTF-8'
            );

        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(120000);

        Http http = new Http();
        HttpResponse res = http.send(req);

        System.debug('Status Code: ' + res.getStatusCode());
        System.debug('Response: ' + res.getBody());

        return res.getBody();
    }
}