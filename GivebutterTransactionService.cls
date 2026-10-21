public with sharing class GivebutterTransactionService {

    public static List<Map<String, Object>> getAllTransactions(
        Date fromDate,
        Date toDate
    ) {

        List<Map<String, Object>> allTransactions =
            new List<Map<String, Object>>();

        /*
         * Convert Salesforce Date values into
         * Givebutter API date/time values.
         *
         * Example:
         * fromDate = 2026-10-07
         * toDate   = 2026-10-07
         *
         * API:
         * transactedAfter=2026-10-07T00:00:00Z
         * transactedBefore=2026-10-07T23:59:59Z
         */

        Datetime fromDateTime = Datetime.newInstanceGmt(
            fromDate.year(),
            fromDate.month(),
            fromDate.day(),
            0,
            0,
            0
        );

        Datetime toDateTime = Datetime.newInstanceGmt(
            toDate.year(),
            toDate.month(),
            toDate.day(),
            23,
            59,
            59
        );

        String fromDateString =
            fromDateTime.formatGmt(
                'yyyy-MM-dd\'T\'HH:mm:ss\'Z\''
            );

        String toDateString =
            toDateTime.formatGmt(
                'yyyy-MM-dd\'T\'HH:mm:ss\'Z\''
            );

        /*
         * First request includes the date filters.
         */
        String nextUrl =
            '/v1/transactions' +
            '?transactedAfter=' +
            EncodingUtil.urlEncode(
                fromDateString,
                'UTF-8'
            ) +
            '&transactedBefore=' +
            EncodingUtil.urlEncode(
                toDateString,
                'UTF-8'
            );

        Http http = new Http();

        while (nextUrl != null) {

            HttpRequest req = new HttpRequest();

            /*
             * Givebutter's "next" link can be a full URL.
             *
             * Named Credential requires:
             *
             * callout:Givebutter_API
             *
             * so convert the full Givebutter URL
             * into a relative path.
             */
            if (nextUrl.startsWith(
                'https://api.givebutter.com'
            )) {

                nextUrl =
                    nextUrl.substring(
                        'https://api.givebutter.com'.length()
                    );
            }

            req.setEndpoint(
                'callout:Givebutter_API' + nextUrl
            );

            req.setMethod('GET');

            req.setHeader(
                'Accept',
                'application/json'
            );

            req.setTimeout(120000);

            HttpResponse res = http.send(req);

            System.debug(
                'Givebutter Status: ' +
                res.getStatusCode()
            );

            if (res.getStatusCode() < 200 ||
                res.getStatusCode() >= 300) {

                throw new CalloutException(
                    'Givebutter API Error: ' +
                    res.getStatusCode() +
                    ' - ' +
                    res.getBody()
                );
            }

            /*
             * Convert JSON response into
             * Map<String, Object>.
             */
            Map<String, Object> response =
                (Map<String, Object>)
                JSON.deserializeUntyped(
                    res.getBody()
                );

            /*
             * Get transactions from this page.
             */
            List<Object> pageData =
                (List<Object>) response.get('data');

            if (pageData != null) {

                for (Object transactionData : pageData) {

                    allTransactions.add(
                        (Map<String, Object>)
                        transactionData
                    );
                }
            }

            System.debug(
                'Transactions retrieved in this page: ' +
                (
                    pageData == null
                    ? 0
                    : pageData.size()
                )
            );

            System.debug(
                'Total transactions retrieved: ' +
                allTransactions.size()
            );

            /*
             * Get pagination links.
             */
            Map<String, Object> links =
                (Map<String, Object>)
                response.get('links');

            if (links != null &&
                links.get('next') != null) {

                nextUrl =
                    (String) links.get('next');

            } else {

                nextUrl = null;
            }
        }

        System.debug(
            'TOTAL GIVEBUTTER TRANSACTIONS: ' +
            allTransactions.size()
        );

        return allTransactions;
    }
}