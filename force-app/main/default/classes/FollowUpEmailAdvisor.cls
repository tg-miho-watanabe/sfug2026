public class FollowUpEmailAdvisor {

    public class ActionInput {
        @InvocableVariable(label='対象商談名（部分一致）' required=false)
        public String opportunityName;

        @InvocableVariable(label='対象ユーザーID' required=false)
        public String userId;
    }

    public class ActionOutput {
        @InvocableVariable(label='商談情報JSON')
        public String opportunityJson;

        @InvocableVariable(label='対象商談数')
        public Integer totalCount;
    }

    public class OppSummary {
        public String opportunityId;
        public String opportunityName;
        public String accountName;
        public String contactName;
        public String loginUserName;
        public String stageName;
        public Date   closeDate;
        public String nextStep;
        public Date   lastActivityDate;
        public List<String> recentActivities;
        public List<String> recentEmails;
    }

    @InvocableMethod(
        label='フォローアップ対象商談取得'
        description='次回打ち合わせ未設定の商談と直近のやり取りを取得する'
        category='Sales'
    )
    public static List<ActionOutput> getFollowUpTargets(List<ActionInput> inputs) {

        ActionInput inp = inputs[0];
        String uid = String.isBlank(inp.userId) ? UserInfo.getUserId() : inp.userId;

        Date today = Date.today();
        
        // ログインユーザー名を取得
        String loginUserName = [SELECT LastName FROM User WHERE Id = :uid LIMIT 1].LastName;

        // ── 1. 次回打ち合わせ未設定の商談を検出 ─────────────────────
        // 条件：自分の未完了商談 かつ 今後2週間以内にEventなし
        Set<Id> oppIdsWithEvent = new Set<Id>();
        for (Event e : [
            SELECT WhatId
            FROM   Event
            WHERE  OwnerId       = :uid
              AND  StartDateTime >= :DateTime.now()
              AND  StartDateTime <= :DateTime.now().addDays(14)
              AND  WhatId        != null
        ]) {
            oppIdsWithEvent.add(e.WhatId);
        }

        // 商談を取得（特定商談名で絞り込みも可能）
        String oppNameFilter = '%' + (String.isBlank(inp.opportunityName) ? '' : inp.opportunityName) + '%';

        List<Opportunity> opps = [
            SELECT Id, Name, StageName, CloseDate, NextStep,
                   LastActivityDate, Account.Name
            FROM   Opportunity
            WHERE  OwnerId = :uid
              AND  IsClosed = false
              AND  Name LIKE :oppNameFilter
              AND  Id NOT IN :oppIdsWithEvent
            ORDER BY LastActivityDate ASC NULLS FIRST
            LIMIT 5
        ];

        List<OppSummary> results = new List<OppSummary>();

        for (Opportunity opp : opps) {

            OppSummary os       = new OppSummary();
            os.opportunityId    = opp.Id;
            os.opportunityName  = opp.Name;
            os.accountName      = opp.Account?.Name;
            os.stageName        = opp.StageName;
            os.closeDate        = opp.CloseDate;
            os.nextStep         = opp.NextStep;
            os.lastActivityDate = opp.LastActivityDate != null
                                  ? opp.LastActivityDate: null;

        // ── 2. 直近のActivity（Task/Event）を取得 ─────────────────────
        os.recentActivities = new List<String>();

        // 完了タスクを取得
        for (Task t : [
            SELECT Subject, ActivityDate, Description
            FROM   Task
            WHERE  WhatId    = :opp.Id
              AND  IsClosed  = true
            ORDER BY ActivityDate DESC
            LIMIT  3
        ]) {
            String entry = t.ActivityDate != null
                ? t.ActivityDate.format() : '';
            entry += ' ' + t.Subject;
            if (String.isNotBlank(t.Description)) {
                entry += '：' + t.Description.left(100);
            }
            os.recentActivities.add(entry);
        }

        // 過去のイベントを取得
        for (Event e : [
            SELECT Subject, StartDateTime, Description
            FROM   Event
            WHERE  WhatId        = :opp.Id
              AND  StartDateTime <= :DateTime.now()
            ORDER BY StartDateTime DESC
            LIMIT  3
        ]) {
            String entry = e.StartDateTime.date().format()
                + ' ' + e.Subject;
            if (String.isNotBlank(e.Description)) {
                entry += '：' + e.Description.left(100);
            }
            os.recentActivities.add(entry);
        }

            // ── 3. 直近のEmailMessageを取得 ───────────────────────
            os.recentEmails = new List<String>();
            for (EmailMessage em : [
                SELECT Subject, FromName, MessageDate, TextBody, Incoming
                FROM   EmailMessage
                WHERE  RelatedToId = :opp.Id
                ORDER BY MessageDate DESC
                LIMIT  3
            ]) {
                String direction = em.Incoming ? '受信' : '送信';
                String entry = em.MessageDate.date().format()
                    + '【' + direction + '】'
                    + em.Subject
                    + '（' + em.FromName + '）';
                if (String.isNotBlank(em.TextBody)) {
                    entry += '：' + em.TextBody.left(150);
                }
                os.recentEmails.add(entry);
            }
            os.loginUserName = loginUserName;

            List<OpportunityContactRole> roles = [
                SELECT Contact.LastName
                FROM   OpportunityContactRole
                WHERE  OpportunityId = :opp.Id
                  AND  IsPrimary     = true
                LIMIT  1
            ];
            if (!roles.isEmpty()) {
                os.contactName = roles[0].Contact.LastName;
            } else {
                List<OpportunityContactRole> anyRoles = [
                    SELECT Contact.LastName
                    FROM   OpportunityContactRole
                    WHERE  OpportunityId = :opp.Id
                    LIMIT  1
                ];
                os.contactName = anyRoles.isEmpty()? '担当者様': anyRoles[0].Contact.LastName;
            }
            results.add(os);
        }

        ActionOutput out       = new ActionOutput();
        out.opportunityJson    = JSON.serialize(results);
        out.totalCount         = results.size();

        return new List<ActionOutput>{ out };
    }
}