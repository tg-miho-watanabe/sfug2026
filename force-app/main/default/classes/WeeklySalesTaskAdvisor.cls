public class WeeklySalesTaskAdvisor {

    // ─── Input / Output 定義 ───────────────────────────────────────
    public class ActionInput {
        @InvocableVariable(label='対象ユーザーID' required=false)
        public String userId;  // 省略時はログインユーザー
    }

    public class ActionOutput {
        @InvocableVariable(label='優先タスクJSON')
        public String prioritizedTasksJson;

        @InvocableVariable(label='取得件数')
        public Integer totalCount;
    }

    public class SalesItem {
        public String type;          // 'Opportunity' | 'Task' | 'Event'
        public String recordId;
        public String name;
        public String accountName;
        public Decimal amount;
        public Date   closeDate;
        public String stage;
        public String nextStep;
        public Date   lastActivityDate;
        public Date   dueDate;
        public String description;
        public Integer priorityScore;
        public String priorityReason;
        public String recordUrl;
        public String emailFrom;
        public String emailPreview;
    }

    // ─── メイン ────────────────────────────────────────────────────
    @InvocableMethod(
        label='週次営業タスク取得'
        description='商談・未完了タスク・今週イベントを取得し優先度スコアで上位10件を返す'
        category='Sales'
    )
    public static List<ActionOutput> getPrioritizedTasks(List<ActionInput> inputs) {

        ActionInput inp = inputs[0];
        String uid = String.isBlank(inp.userId) ? UserInfo.getUserId() : inp.userId;

        Date today    = Date.today();
        Date weekEnd  = today.addDays(7 - Math.mod(Date.today().toStartOfWeek().daysBetween(today), 7));
        // 今週の月〜日
        Date weekStart = today.toStartOfWeek();
        
        String baseUrl = System.URL.getOrgDomainUrl().toExternalForm();
        List<SalesItem> items = new List<SalesItem>();

        // ── 1. 商談取得 ─────────────────────────────────────────────
        for (Opportunity opp : [
            SELECT Id, Name, Amount, CloseDate, StageName, NextStep,
                   LastActivityDate, Account.Name
            FROM   Opportunity
            WHERE  OwnerId = :uid
              AND  IsClosed = false
            ORDER BY CloseDate ASC
            LIMIT 50
        ]) {
            SalesItem si   = new SalesItem();
            si.type        = 'Opportunity';
            si.recordId    = opp.Id;
            si.name        = opp.Name;
            si.accountName = opp.Account?.Name;
            si.amount      = opp.Amount;
            si.closeDate   = opp.CloseDate;
            si.stage       = opp.StageName;
            si.nextStep    = opp.NextStep;
            si.lastActivityDate = opp.LastActivityDate != null
                                  ? opp.LastActivityDate : null;
            si.priorityScore  = calcScore(si, today, weekEnd);
            si.priorityReason = buildReason(si, today, weekEnd);
            si.recordUrl = baseUrl + '/' + opp.Id;
            items.add(si);
        }

        // ── 2. 未完了タスク取得 ──────────────────────────────────────
        List<Task> rawTasks = [
                SELECT Id, Subject, ActivityDate, Description,
                       What.Name, WhatId
                FROM   Task
                WHERE  OwnerId   = :uid
                  AND  IsClosed  = false
                  AND  (ActivityDate = null OR ActivityDate <= :weekEnd)
                ORDER BY ActivityDate ASC NULLS LAST
                LIMIT  30
        ];

        // WhatIdがOpportunityのタスクだけ取引先名を別途取得
        Set<Id> oppIds = new Set<Id>();
        for (Task t : rawTasks) {
                if (t.WhatId != null && String.valueOf(t.WhatId).startsWith('006')) {
                        oppIds.add(t.WhatId);
                }
        }

        // OpportunityIdをキーに取引先名マップを作成
        Map<Id, String> oppAccountMap = new Map<Id, String>();
        for (Opportunity o : [
                SELECT Id, Account.Name
                FROM   Opportunity
                WHERE  Id IN :oppIds
        ]) {
                oppAccountMap.put(o.Id, o.Account?.Name);
        }

        for (Task t : rawTasks) {
                SalesItem si   = new SalesItem();
                si.type        = 'Task';
                si.recordId    = t.Id;
                si.name        = t.Subject;

                // 取引先名：OpportunityのAccountを優先、それ以外はWhat.Name
                if (t.WhatId != null && oppAccountMap.containsKey(t.WhatId)) {
                        si.accountName = oppAccountMap.get(t.WhatId);
                } else {
                        si.accountName = t.What?.Name;
                }

                si.dueDate        = t.ActivityDate;
                si.description    = t.Description;
                si.priorityScore  = calcScoreTask(si, today, weekEnd);
                si.priorityReason = buildReasonTask(si, today, weekEnd);
                si.recordUrl = baseUrl + '/' + t.Id;
                items.add(si);
        }
        // ── 3. 今週のイベント取得 ────────────────────────────────────
        for (Event e : [
            SELECT Id, Subject, StartDateTime, EndDateTime,
                   What.Name, Description
            FROM   Event
            WHERE  OwnerId              = :uid
              AND  StartDateTime       >= :weekStart
              AND  StartDateTime       <= :weekEnd
            ORDER BY StartDateTime ASC
            LIMIT  20
        ]) {
            SalesItem si   = new SalesItem();
            si.type        = 'Event';
            si.recordId    = e.Id;
            si.name        = e.Subject;
            si.accountName = e.What?.Name;
            si.dueDate     = e.StartDateTime.date();
            si.description = e.Description;
            si.priorityScore  = 25; // イベントは固定スコア
            si.priorityReason = '今週のイベント';
            si.recordUrl = baseUrl + '/' + e.Id;
            items.add(si);
        }
        // ── 4. 未返信メール取得 ─────────────────────────────────────
        // 対象商談のIDセットを作成
        Set<Id> oppIdSet = new Set<Id>();
        for (SalesItem si : items) {
                if (si.type == 'Opportunity') {
                        oppIdSet.add(si.recordId);
                }
        }

        if (!oppIdSet.isEmpty()) {
                for (EmailMessage em : [
                        SELECT Id, Subject, FromAddress, FromName,
                               MessageDate, RelatedToId, TextBody
                        FROM   EmailMessage
                        WHERE  RelatedToId IN :oppIdSet
                          AND  Incoming     = true
                          AND  MessageDate >= :today.addDays(-7)
                        ORDER BY MessageDate DESC
                        LIMIT  20
                ]) {
                        SalesItem si      = new SalesItem();
                        si.type           = 'Email';
                        si.recordId       = em.Id;
                        si.name           = '📧 ' + em.Subject;
                        si.accountName    = null; // 後でマップから取得
                        si.dueDate     = null;
                        si.description = ''; //受信日を priorityReason に統合して dueDate/description には入れない
                        si.emailFrom      = em.FromName;
                        si.emailPreview   = em.TextBody != null
                                            ? em.TextBody.left(200).replaceAll('\n', ' ')
                                            : '';
                        si.priorityScore  = calcScoreEmail(em, today);
                        si.priorityReason = buildReasonEmail(em, today);
                        items.add(si);
                }
        }
        // ── 4. スコア降順ソート → 上位10件 ──────────────────────────
        items.sort(new ScoreComparator());
        List<SalesItem> top10 = new List<SalesItem>();
        for (Integer i = 0; i < Math.min(10, items.size()); i++) {
            top10.add(items[i]);
        }

        // ── 5. JSON化して返却 ────────────────────────────────────────
        ActionOutput out    = new ActionOutput();
        out.prioritizedTasksJson = JSON.serialize(top10);
        out.totalCount           = top10.size();

        return new List<ActionOutput>{ out };
    }

    // ─── 商談スコア算出 ────────────────────────────────────────────
    private static Integer calcScore(SalesItem si, Date today, Date weekEnd) {
        Integer score = 0;

        // Close Dateが今週 +30
        if (si.closeDate != null
            && si.closeDate >= today && si.closeDate <= weekEnd) {
            score += 30;
        }
        // 金額が大きい（100万以上） +20
        if (si.amount != null && si.amount >= 1000000) {
            score += 20;
        }
        // 最終活動7日以上なし +20
        if (si.lastActivityDate == null
            || today.daysBetween(si.lastActivityDate) >= 7) {
            score += 20;
        }
        // Close Date 30日以内に接近 +15
        if (si.closeDate != null) {
            Integer daysToClose = today.daysBetween(si.closeDate);
            if (daysToClose >= 0 && daysToClose <= 30) score += 15;
        }
        // Next Step 未入力 +15
        if (String.isBlank(si.nextStep)) score += 15;

        return score;
    }

    // ─── タスクスコア算出 ──────────────────────────────────────────
    private static Integer calcScoreTask(SalesItem si, Date today, Date weekEnd) {
        Integer score = 0;
        // 期限が今週 +30
        if (si.dueDate != null
            && si.dueDate >= today && si.dueDate <= weekEnd) {
            score += 30;
        }
        // 期限切れ +40（超優先）
        if (si.dueDate != null && si.dueDate < today) {
            score += 40;
        }
        // 期限なし +10
        if (si.dueDate == null) score += 10;
        return score;
    }

    // ─── 理由文生成 ───────────────────────────────────────────────
    private static String buildReason(SalesItem si, Date today, Date weekEnd) {
        List<String> reasons = new List<String>();
        if (si.closeDate != null && si.closeDate >= today && si.closeDate <= weekEnd)
            reasons.add('今週がClose Date');
        if (si.amount != null && si.amount >= 1000000)
            reasons.add('高額案件');
        if (si.lastActivityDate == null || today.daysBetween(si.lastActivityDate) >= 7)
            reasons.add('7日以上活動なし');
        if (si.closeDate != null && today.daysBetween(si.closeDate) <= 30)
            reasons.add('30日以内にClose Date');
        if (String.isBlank(si.nextStep))
            reasons.add('Next Step未入力');
        return String.join(reasons, ' / ');
    }

    private static String buildReasonTask(SalesItem si, Date today, Date weekEnd) {
        if (si.dueDate != null && si.dueDate < today) return '期限切れ';
        if (si.dueDate != null && si.dueDate >= today && si.dueDate <= weekEnd)
            return '今週が期限';
        return '未完了タスク';
    }

    // ─── メールスコア算出 ──────────────────────────────────────
    private static Integer calcScoreEmail(EmailMessage em, Date today) {
        Integer daysAgo = em.MessageDate.date().daysBetween(today);
        if (daysAgo == 0)      return 35;
        else if (daysAgo <= 2) return 25;
        else                   return 15;
    }

    private static String buildReasonEmail(EmailMessage em, Date today) {
        Integer daysAgo = em.MessageDate.date().daysBetween(today);
        String daysText = daysAgo == 0 ? '本日' : daysAgo + '日前';
        return '【受信メール】' + daysText + '受信。返信を検討してください。';
    }
    // ─── Comparator ───────────────────────────────────────────────
    private class ScoreComparator implements Comparator<SalesItem> {
        public Integer compare(SalesItem a, SalesItem b) {
            return b.priorityScore - a.priorityScore; // 降順
        }
    }
}