defmodule OptimalEngine.SignalEvalBlind do
  @moduledoc "Held-out, independently written evaluation samples for signal mode and genre classification. Written without reference to the classifier or to any other evaluation data. Each sample has :id, :text, :mode (:linguistic, :code, :data, :visual or :mixed) and :genre (a genre string or nil). All content is fictional."

  def samples do
    [
      # ------------------------------------------------------------------
      # Transcripts
      # ------------------------------------------------------------------
      %{
        id: "bl-transcript-01",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        Priya: Okay, are we recording? Good. So the main thing today is the import job.
        Marcus: Right. The import still chokes on the legacy accounts. We require a first-class fix, not another patch.
        Priya: Agreed. What's the return on doing the full rewrite versus just the parser?
        Marcus: Parser alone gets us most of it. Maybe two weeks.
        Jo: I'd push back a little. The parser isn't the problem, it's the mapping step. Account goes to region goes to owner, and when the owner is missing the whole chain dies.
        Priya: So account -> region -> owner, and owner is null.
        Jo: Exactly.
        Marcus: Fine, then both. Parser and a fallback for orphaned accounts.
        Priya: Can you write that up by Thursday?
        Jo: Yeah, I'll take it.
        """
      },
      %{
        id: "bl-transcript-02",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        [00:00:04] Interviewer: Thanks for making time. Can you start by walking me through a normal week?
        [00:00:11] Ruth: Sure. Mondays are mostly reconciliation. I pull the statements from the three banks, line them up against what the field teams submitted, and flag anything over fifty dollars that doesn't match.
        [00:00:29] Interviewer: How long does that take?
        [00:00:31] Ruth: On a good week, a morning. On a bad week, the whole day and some of Tuesday.
        [00:00:38] Interviewer: What makes a week bad?
        [00:00:41] Ruth: Receipts that come in as photos of photos. Or someone splits one dinner across four cards. Honestly the worst is when a vendor changes their name on the statement and I have to figure out it's the same caterer.
        [00:01:02] Interviewer: If you could change one thing about the process, what would it be?
        [00:01:06] Ruth: I'd want the receipts attached at the time of purchase. Not a week later when nobody remembers what it was.
        [00:01:14] Interviewer: That's really helpful. Do you use any shortcuts or templates today?
        [00:01:19] Ruth: I have a spreadsheet with a tab per bank. It's held together with tape, but it works.
        """
      },
      %{
        id: "bl-transcript-03",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        Host: Hi everyone, I think we have the right people. Ben, do you want to kick off?
        Ben: Yeah. So we've been on the starter tier for about eight months and we're bumping into the seat limit every few weeks.
        Host: Got it. How many seats are you at right now?
        Ben: Twenty-two, and the cap is twenty-five. We're hiring six more this quarter.
        Carla: And the bigger issue for me is the audit log. Our compliance person keeps asking for it and it's only on the top tier.
        Host: That's fair feedback. There is a middle option we don't advertise much, it includes the audit log and goes up to fifty seats.
        Carla: Why don't you advertise it?
        Host: (laughs) Good question. I'll pass that along. Let me send you the details after the call and we can set up a trial on your current workspace so nothing has to move.
        Ben: That works. Can the trial start before the end of the month? Our renewal is on the twenty-ninth.
        Host: I'll make sure it does.
        """
      },
      %{
        id: "bl-transcript-04",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        So, um, the thing nobody tells you about running a small bakery is that the ovens are the easy part. Like, you learn the ovens in a month. What takes years is the scheduling. You've got dough that needs twelve hours, you've got the morning crew that can't start before five because of the bus, and you've got, uh, wholesale orders that come in at nine at night saying hey, can we get forty more rolls tomorrow. And you say yes, because you always say yes, and then you're up at three doing math on the back of a flour bag. I think if I had one piece of advice it'd be, write the schedule backward. Start from when the customer picks up and walk it back hour by hour. It sounds obvious. It took me four years.
        """
      },
      %{
        id: "bl-transcript-05",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        Lena: Okay, screen share is up. This is the new settings page.
        Tom: Can you zoom in on the left nav? The spacing looks off.
        Lena: Yeah, that's a known thing, the padding comes from the old layout class and I haven't overridden it yet.
        Tom: Is that the same class the billing page uses?
        Lena: Same one. If I change it there it changes everywhere, so I'd rather scope it.
        Omar: Quick question on the toggle. When you flip notifications off, what does the request return? Do we wait for the server or just flip it?
        Lena: Optimistic. We flip it, fire the request, and if it comes back with an error we flip it back and show a toast.
        Omar: Okay. And the const for the debounce is still three hundred milliseconds?
        Lena: It's three hundred, yeah. Honestly I'd go lower.
        Tom: Let's not change two things at once. Ship the page, then tune it.
        Lena: Fair.
        """
      },
      %{
        id: "bl-transcript-06",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        Agent: Thanks for calling, this is Nadia. Can I get the email on the account?
        Caller: It's gina at example.com.
        Agent: Got it, I see you. What's going on today?
        Caller: I was charged twice for March. Same amount, same day.
        Agent: I'm sorry about that. Let me look. Okay, I do see two charges on the third. One of them shows as pending and the other went through.
        Caller: So is the pending one going to go away?
        Agent: Usually within three to five business days, yes. If it posts, call us back and we'll refund it right away. You won't have to explain it again, I'm adding a note now.
        Caller: Okay. That's fine.
        Agent: Is there anything else I can help with?
        Caller: No, that's it. Thanks.
        """
      },
      %{
        id: "bl-transcript-07",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        Moderator: We've got a few minutes for questions. First one from the chat: "Are we still planning to open the second office next year?"
        Hannah: Short answer, yes, but probably later than we said in the spring. The lease we wanted fell through, and I'd rather wait for the right space than sign something that doesn't fit.
        Moderator: Next: "Will the bonus structure change with the new levels?"
        Hannah: It won't change this cycle. We'll share any changes for next year at least a quarter in advance, that's a commitment.
        Moderator: And one more: "What's the plan for the weekly demo, it's been skipped three times."
        Hannah: (laughs) That's on me. We'll bring it back starting next Friday and Felix has volunteered to host. Thanks Felix.
        Felix: I did not volunteer.
        Hannah: You do now.
        """
      },
      %{
        id: "bl-transcript-08",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        SPEAKER 1: I think the honest answer is that most teams don't need microservices. They need clear boundaries inside one codebase.
        SPEAKER 2: I'd agree, with one caveat. If you have two teams that ship on different schedules and keep stepping on each other, splitting the deploy can buy you a lot of peace.
        SPEAKER 1: Sure, but you can split the deploy without splitting the data. That's the part people get wrong. They give every service its own database on day one and then spend a year writing sync jobs.
        SPEAKER 3: Can I jump in? We did exactly that. Seven services, seven databases, and a reporting team that hated us.
        SPEAKER 2: (laughter) What did you end up doing?
        SPEAKER 3: Merged four of them back. It took two quarters. Nobody gives conference talks about merging services back, but they should.
        """
      },
      %{
        id: "bl-transcript-09",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        so the second thing to notice on this slide is that the curve flattens out
        after about week six and a lot of people read that as the treatment
        stopping working but thats not what it means it means the people who
        were going to respond have mostly responded already right so the
        remaining group is harder and you would expect the slope to go down
        any questions on that before we move on yes in the back
        """
      },
      %{
        id: "bl-transcript-10",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        Sara: Let's go around. Overall thumbs, then reasons. Ivan?
        Ivan: Lean yes. The system design round was strong, she asked good clarifying questions before drawing anything.
        Sara: Kofi?
        Kofi: Lean no, but weakly. The coding round was slow. She got there, but she spent ten minutes on a helper function that wasn't really needed.
        Ivan: To be fair, she said out loud that she'd normally skip it and write it later.
        Kofi: She did. I just want to see it, not hear about it.
        Sara: Okay. I'm a yes. The values conversation was the best I've had this month. Sounds like we're two yes and one weak no. Kofi, would you block?
        Kofi: No, I wouldn't block.
        Sara: Then let's move to references. I'll send the summary tonight.
        """
      },
      %{
        id: "bl-transcript-11",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        Ana: Okay, you drive. Start a new file, call it user loader.
        Raj: Done.
        Ana: So first line, const user equals await load user, open paren, id, close paren.
        Raj: Got it.
        Ana: Then if not user, return null. Actually no, throw. We want it to blow up here.
        Raj: Throw a new error, "user not found"?
        Ana: Yeah. And then open curly brace, we return an object with the name and the plan. Name is user dot display name, plan is user dot plan or "free".
        Raj: Should I import the type from the shared folder?
        Ana: Yes, import it, don't redeclare it. Last time someone redeclared it and the two drifted apart for a month.
        Raj: Okay, saving. Want me to run the tests?
        Ana: Run them. Then we'll look at why the old one was slow.
        """
      },
      %{
        id: "bl-transcript-12",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        Chair: Item four, the facilities budget. Gloria, over to you.
        Gloria: Thank you. We came in about eleven percent over on maintenance, mostly the roof repair in February, which wasn't planned.
        Member: Was that covered by insurance at all?
        Gloria: Partially. We expect about four thousand back, but it hasn't arrived yet, so it's not in these numbers.
        Member: Then I'd move that we note the overage but not adjust next year's line until the reimbursement comes in.
        Chair: Is there a second?
        Member 2: Second.
        Chair: All in favor? Opposed? Abstentions? Motion carries. Gloria, can you bring the updated figure to the next meeting?
        Gloria: I will.
        """
      },
      %{
        id: "bl-transcript-13",
        mode: :linguistic,
        genre: "transcript",
        text: ~S"""
        Facilitator: Let's start with what went well. Just call things out.
        Mei: The handoff between design and dev was way smoother this sprint. Fewer surprises.
        Arlo: Having the review on Tuesday instead of Friday helped a lot.
        Facilitator: Great. What didn't go well?
        Arlo: The flaky test. I lost probably a day total rerunning the pipeline.
        Mei: Same. And nobody owned it, so it just sat there.
        Facilitator: Okay, so ownership of flaky tests. What would we change?
        Arlo: Whoever sees it fail twice opens a ticket and quarantines it. No discussion.
        Mei: I like that. And we review the quarantine list at the start of each sprint so it doesn't grow forever.
        Facilitator: Writing that down as an action. Anything else?
        Mei: Can we stop doing retros at 4:30 on a Friday?
        Facilitator: (laughs) Noted.
        """
      },

      # ------------------------------------------------------------------
      # Emails
      # ------------------------------------------------------------------
      %{
        id: "bl-email-01",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Subject: Contacts import finished, two follow-ups

        Hi Dana,

        The import of the contacts from the old system finished overnight. About 18,400 records came across. A few things worth knowing before you start using them:

        1. The function that merges duplicates only matched on email, so people with two addresses still show up twice. I'd guess a few hundred.
        2. Anyone without a country was set to "Unknown" rather than left blank, because the reporting view requires a value there.

        If you spot anything odd, send me the record and I'll trace it back. I kept the raw export, so nothing is lost.

        Thanks,
        Leo
        """
      },
      %{
        id: "bl-email-02",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Dear Accounts Team,

        Please find attached invoice 2026-0417 for the catering services provided on 9 April. The total due is 2,340.00, payable within 30 days of the invoice date.

        We noticed that invoice 2026-0381 from March is still showing as outstanding on our side. If it has already been paid, could you send us the remittance details so we can reconcile it? If not, we would be grateful if both could be settled together.

        Kind regards,
        Ines
        Office Manager
        """
      },
      %{
        id: "bl-email-03",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        From: marta@example.com
        To: design-team@example.com
        Date: Tue, 3 Mar 2026 09:12
        Subject: Thursday crit moved

        Hi all, quick one. Thursday's crit is moving to 2pm because the big room is booked in the morning. Same link, same agenda. If 2pm doesn't work for you, tell me today and I'll find another slot.

        Marta
        """
      },
      %{
        id: "bl-email-04",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Hi Theo,

        Thanks again for your time on Monday. The team enjoyed the conversation and we'd like to invite you to the final round.

        It's about three hours in total, split into a working session with two engineers, a conversation with our head of product, and a short wrap-up with me. We can do it on site or remotely, whichever you prefer.

        Could you send me two or three windows that work for you next week? Mornings are slightly easier for us, but we'll make anything work.

        Best,
        Rosa
        """
      },
      %{
        id: "bl-email-05",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Subject: Third time asking about our data export

        Hello,

        I'm writing again because I still haven't received a working export of our project history. I first asked on the 2nd, was told it would take 48 hours, and then got a file on the 6th that only included the last 30 days.

        We are moving to another provider at the end of the month and we need the complete history before then. This is not optional for us; our auditors require it.

        Please escalate this to someone who can give me a firm date. I'm available by phone most afternoons.

        Regards,
        Victor
        """
      },
      %{
        id: "bl-email-06",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Sounds good to me. I'll bring the printed copies.

        On Wed, Kai wrote:
        > Can we do the walkthrough Friday instead of Thursday? Half the team is out on Thursday for the training.
        >
        > Also, does anyone have the latest floor plan? The one in the shared folder is from last year.
        >
        > Kai

        Elif
        """
      },
      %{
        id: "bl-email-07",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Subject: Out of office until 14 July

        Thank you for your message. I'm away with limited access to email until Monday 14 July.

        For anything urgent about orders or deliveries, please contact the operations desk at ops@example.com. For billing questions, accounts@example.com will get back to you within one business day.

        I'll reply to everything else when I'm back.

        Lucia
        """
      },
      %{
        id: "bl-email-08",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Hi Sam,

        As part of your last day on Friday, please return the laptop, charger and badge to the front desk by 3pm. If you'd rather drop them at the other office, that's fine, just let me know so I can tell them to expect you.

        Before you hand it over, please make sure anything personal is off the machine. We'll wipe it the same day.

        Your final paycheck will include unused vacation days, and you'll get the benefits information by post within two weeks.

        It's been great working with you. Let me know if anything is unclear.

        Warmly,
        Pat
        People Operations
        """
      },
      %{
        id: "bl-email-09",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Subject: Notes and next steps from today's planning call

        Hi everyone,

        Thanks for a productive hour. Recapping what we agreed:

        - Jonah will draft the scope document for the partner portal and circulate it by Wednesday.
        - Amira will check whether the legal review can start before the scope is final.
        - I'll book a follow-up for next Tuesday and invite finance.

        Open question: do we need the portal in two languages at launch, or can the second one follow a month later? Please reply to this thread with your view.

        Thanks,
        Wen
        """
      },
      %{
        id: "bl-email-10",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Hi team,

        A reminder about a few review conventions, since we've had some back and forth on recent pull requests.

        Please don't add new require statements at the top of shared modules without a short note in the description saying why the dependency is needed. Several of our slow startup issues came from one-line imports that pulled in a lot.

        Class names should describe what the thing is, not what it does once. "InvoiceRenderer" is fine, "DoTheInvoiceThing" is not, and yes, that was a real one.

        Finally, if a function returns early in more than two places, consider splitting it. This isn't a hard rule, it just makes reviews quicker.

        Thanks for keeping the bar high,
        Elena
        """
      },
      %{
        id: "bl-email-11",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Dear Malik,

        Thank you for sending the proposal for the warehouse lighting upgrade and for walking us through the options last week.

        After discussing it internally, we've decided not to go ahead this year. The savings estimate is convincing, but the upfront cost doesn't fit the budget we have left, and we'd prefer to do the whole site at once rather than in phases.

        We'd be glad to revisit this in the spring when next year's capital budget is set. I'll reach out then.

        With thanks,
        Ingrid
        """
      },
      %{
        id: "bl-email-12",
        mode: :linguistic,
        genre: "email",
        text: ~S"""
        Subject: This week in the studio

        Hi all,

        A few quick updates before the weekend.

        The new kiln is finally installed and tested. Please book it through the sign-up sheet by the door rather than just loading it, we had two people's work in it at once on Tuesday.

        Our winter open studio date is set for 6 December. If you'd like to show work, tell Rafa by the end of the month.

        And a thank you to everyone who stayed late to clean the glaze room. It has never looked this good.

        See you Monday,
        June
        """
      },

      # ------------------------------------------------------------------
      # Chat messages
      # ------------------------------------------------------------------
      %{
        id: "bl-message-01",
        mode: :linguistic,
        genre: "message",
        text:
          "hey @sam can you rerun the `deploy-staging` job? it flaked on the dependency install step again"
      },
      %{
        id: "bl-message-02",
        mode: :linguistic,
        genre: "message",
        text: "lunch at 12:30? usual place, my treat since I bailed last week"
      },
      %{
        id: "bl-message-03",
        mode: :linguistic,
        genre: "message",
        text: "Thanks Maya, merging now"
      },
      %{
        id: "bl-message-04",
        mode: :linguistic,
        genre: "message",
        text:
          "@here heads up: the shared drive goes read-only tonight from 6 to 8pm for maintenance. save your work before then, anything written during the window will be lost"
      },
      %{
        id: "bl-message-05",
        mode: :linguistic,
        genre: "message",
        text:
          "the flow is signup -> verify email -> pick plan -> invite team, and we lose about 40% of people between verify and pick plan. my guess is the email takes too long to arrive"
      },
      %{
        id: "bl-message-06",
        mode: :linguistic,
        genre: "message",
        text:
          "found it. line 88 has `if (!user) return` before the cache write, so for logged-out visitors we never populate the cache and every request hits the db. moving the write above the guard should fix it"
      },
      %{
        id: "bl-message-07",
        mode: :linguistic,
        genre: "message",
        text: ~S"""
        Hey Iris, wanted to give you a heads up before the review tomorrow. The vendor pushed the delivery date again, now it's the 20th. I know you told the client the 12th. I think we should tell them today rather than in the meeting, so they don't hear it with everyone watching. Happy to draft the note if that helps, or jump on a call this afternoon.
        """
      },
      %{
        id: "bl-message-08",
        mode: :linguistic,
        genre: "message",
        text:
          "did you see yesterday's numbers?? signups basically doubled after the newsletter went out"
      },
      %{
        id: "bl-message-09",
        mode: :linguistic,
        genre: "message",
        text:
          "Oye Lu, ya mandé el contrato firmado. Avísame si falta alguna página o si necesitan otra copia."
      },
      %{
        id: "bl-message-10",
        mode: :linguistic,
        genre: "message",
        text: "sorry, wrong channel, ignore that"
      },
      %{
        id: "bl-message-11",
        mode: :linguistic,
        genre: "message",
        text:
          "@Nico when you get a minute, could you look at my PR for the retry logic? it's small, ~60 lines. mostly unsure whether `maxAttempts` should live in config or stay a constant"
      },
      %{
        id: "bl-message-12",
        mode: :linguistic,
        genre: "message",
        text:
          "+1 to what Lena said. also we should pin the version in the lockfile, last time a minor bump broke the date picker"
      },
      %{
        id: "bl-message-13",
        mode: :linguistic,
        genre: "message",
        text: ~S"""
        Morning team!
        Reminder that the office is closed Monday for the holiday. On-call is Dev this weekend and Priya next week.
        Have a good long weekend everyone
        """
      },
      %{
        id: "bl-message-14",
        mode: :linguistic,
        genre: "message",
        text:
          "quick q: are we doing {first name} {last name} in the greeting or just {first name}? marketing sent both versions and I don't want to guess"
      },

      # ------------------------------------------------------------------
      # Notes
      # ------------------------------------------------------------------
      %{
        id: "bl-note-01",
        mode: :linguistic,
        genre: "note",
        text: ~S"""
        onboarding idea
        - user lands -> if invited, skip the plan picker
        - else show 3 plans, default to the middle one
        - on pick -> create workspace -> seed a sample project
        - if they bail during seeding, still keep the workspace (don't delete!)
        - maybe: email a nudge after 24h if the sample project was never opened
        """
      },
      %{
        id: "bl-note-02",
        mode: :linguistic,
        genre: "note",
        text:
          "call the accountant before friday re: quarterly estimate. ask about the home office deduction too"
      },
      %{
        id: "bl-note-03",
        mode: :linguistic,
        genre: "note",
        text: ~S"""
        Ch. 4, on habits
        - the cue matters more than the reward, at least early on
        - "make it obvious" = put the thing where you'll trip over it
        - example of the guy who left his running shoes by the bed. a bit cheesy but it works
        - disagree with the bit about willpower being a myth. it's limited, not imaginary
        - try: keep the guitar out of the case for two weeks and see if I play more
        """
      },
      %{
        id: "bl-note-04",
        mode: :linguistic,
        genre: "note",
        text: ~S"""
        Session 3, participant was a nurse, late 40s, uses the app on her phone between rounds.

        - Did not notice the search bar at all. Scrolled the full list twice looking for a patient.
        - Tapped the patient name expecting details, got the chart instead. Said "oh, that's fine actually."
        - Read every word of the warning dialog, which surprised me. Most people skip it.
        - Asked why the font got smaller on the second screen. Good question, it shouldn't.

        Takeaway: search needs to be the first thing on the screen, not tucked under the header.
        """
      },
      %{
        id: "bl-note-05",
        mode: :linguistic,
        genre: "note",
        text:
          "what if the weekly digest was opt-out instead of opt-in? way more readers, but also more unsubscribes and maybe spam complaints. worth testing on new signups only"
      },
      %{
        id: "bl-note-06",
        mode: :linguistic,
        genre: "note",
        text:
          "pick up: batteries (AA), packing tape, birthday card for Ana, return the library books"
      },
      %{
        id: "bl-note-07",
        mode: :linguistic,
        genre: "note",
        text: ~S"""
        export bug, notes so far
        - happens only for workspaces created before the March change
        - tried clearing the cache: no difference
        - tried exporting as a new user in the same workspace: still broken, so not a permission thing
        - the job doesn't throw, it just returns an empty file. suspicious
        - old workspaces store dates as text, new ones as timestamps. the filter probably compares text to a timestamp and matches nothing
        - next: check what the filter receives for an old workspace, don't change anything yet
        """
      },
      %{
        id: "bl-note-08",
        mode: :linguistic,
        genre: "note",
        text: ~S"""
        Talk: "Boring technology, ten years later"
        Speaker opened with a slide of every tool her team adopted and dropped. Maybe forty logos. Point being, novelty has a maintenance cost that shows up two years later.
        Good line: "Every new tool is a loan. You pay interest in onboarding."
        She recommended a yearly "tool funeral" where the team retires one thing. I like that, could do it at the January offsite.
        Q&A was mostly people asking how to convince their managers. Her answer: show the on-call pages, not the architecture diagram.
        """
      },
      %{
        id: "bl-note-09",
        mode: :linguistic,
        genre: "note",
        text: ~S"""
        refactor order (thinking out loud)
        {auth, billing} both read the session directly -> pull session into its own module first
        then billing -> stop reaching into user.settings, pass in only what it needs
        auth last, it's the scariest
        don't touch reports at all this round, it's fine and nobody complains
        """
      },
      %{
        id: "bl-note-10",
        mode: :linguistic,
        genre: "note",
        text: ~S"""
        Tuesday. Slept badly, too much coffee after lunch again. The client call went better than I expected, they didn't push back on the timeline at all, which makes me think they weren't really listening. Need to send the summary in writing so it's on record. Walked home the long way by the river. Should do that more.
        """
      },
      %{
        id: "bl-note-11",
        mode: :linguistic,
        genre: "note",
        text: ~S"""
        1:1 w/ Joel, Mar 12
        - he wants more ownership, specifically the search project
        - worried about becoming "the bug fixer" on the team
        - I said yes to search, with Lin as reviewer for the first month
        - he'll present the plan at the next team sync
        - follow up in two weeks on how the split with support rotation is going
        """
      },
      %{
        id: "bl-note-12",
        mode: :linguistic,
        genre: "note",
        text: ~S"""
        - [x] renew the domain
        - [ ] update the footer year
        - [ ] ask Pia for the new headshots
        - [ ] fix the broken link on the pricing page
        - [ ] cancel the old analytics trial before it bills
        """
      },
      %{
        id: "bl-note-13",
        mode: :linguistic,
        genre: "note",
        text:
          "idea for hiring: instead of the take-home, do a paid half day. candidate works on a real (small, non-sensitive) ticket with someone from the team, and we pay them for the time either way. fairer, and we'd learn more than from a puzzle. downside: scheduling is harder and it doesn't scale past a few candidates a month. try it for the next two roles?"
      },
      %{
        id: "bl-note-14",
        mode: :linguistic,
        genre: "note",
        text: ~S"""
        Pricing thoughts after the call with the two agencies:
        1. Per-seat pricing punishes them for adding freelancers for a single project.
        2. They'd happily pay more for a flat team plan if guests were free.
        3. Neither cared about the API limits. Nobody asked.
        4. Annual discount is fine at 15%, 20% felt like we were desperate.
        Not ready to change anything. Want five more conversations first.
        """
      },

      # ------------------------------------------------------------------
      # Specs
      # ------------------------------------------------------------------
      %{
        id: "bl-spec-01",
        mode: :linguistic,
        genre: "spec",
        text: ~S"""
        # Saved Filters

        ## Goal
        Let users save a combination of filters on the orders list and come back to it with one click.

        ## Requirements
        - A user can save the current filters under a name of up to 60 characters.
        - Saved filters are private by default and can be shared with the whole workspace.
        - Opening a saved filter replaces the current filters; it does not merge with them.
        - If a saved filter refers to a field that no longer exists, the filter still opens and shows a warning instead of failing.
        - The API must return 404 when a user requests a saved filter they cannot see, not 403, so we don't leak that it exists.

        ## Non-goals
        - Scheduled email reports based on saved filters. That is a separate project.
        - Filters across multiple workspaces.

        ## Open questions
        - Do we cap the number of saved filters per user?
        """
      },
      %{
        id: "bl-spec-02",
        mode: :linguistic,
        genre: "spec",
        text: ~S"""
        Notification preferences, v1 spec

        Summary: users choose, per category, whether they get a notification in the app, by email, both, or neither.

        Categories at launch are mentions, assignments, due date reminders and the weekly summary. Mentions and assignments default to both. Reminders default to in-app only. The weekly summary defaults to email only and is the only category a user can turn off for the entire workspace at once.

        Changes take effect immediately for new notifications. Anything already queued is sent according to the old setting; we decided this is acceptable because the queue is rarely more than a minute deep.

        Workspace admins cannot override a user's choice. They can set the defaults for new members.

        Out of scope for v1: quiet hours, digest frequency other than weekly, and per-project overrides.
        """
      },
      %{
        id: "bl-spec-03",
        mode: :linguistic,
        genre: "spec",
        text: ~S"""
        Webhook delivery and retries

        1. A delivery is successful when the receiver responds with any 2xx status within 10 seconds.
        2. Any other outcome, including timeouts and connection errors, MUST be retried.
        3. Retries MUST use exponential backoff starting at 30 seconds, doubling each time, with a maximum interval of 6 hours.
        4. The sender MUST stop retrying 24 hours after the first attempt and mark the delivery as failed.
        5. Receivers SHOULD treat deliveries as at-least-once and deduplicate on the event id.
        6. The sender MAY disable an endpoint after 3 consecutive days of failed deliveries, and MUST notify the workspace owner when it does.
        7. Delivery order is not guaranteed. Receivers MUST NOT assume event B arrives after event A even if it happened later.
        """
      },
      %{
        id: "bl-spec-04",
        mode: :linguistic,
        genre: "spec",
        text: ~S"""
        Spec: people search in the internal directory

        Problem
        People can't find colleagues unless they already know how the name is spelled. Searches for nicknames and partial names return nothing.

        What we're building
        A single search box that matches first name, last name, preferred name, team and role, tolerant of small typos. Results show photo, name, team and local time. Typing three characters is enough to start showing results.

        Rules
        Results are ordered by exact match first, then same team as the searcher, then everyone else alphabetically. Former employees never appear. Contractors appear with a label.

        Success looks like
        Fewer than 5% of searches end with zero results, measured over the first month.
        """
      },
      %{
        id: "bl-spec-05",
        mode: :linguistic,
        genre: "spec",
        text: ~S"""
        Data retention requirements (draft 2)

        Customer uploads are kept for the life of the account and deleted within 30 days of account closure. Backups containing those uploads age out on the normal 35-day cycle; we do not edit backups to remove individual files.

        Access logs are kept for 13 months so we can compare year over year, then deleted. Logs must not contain message contents or file names, only identifiers.

        Billing records are kept for 7 years because of tax law, even after the account is closed. These are stored separately from product data and are not restored into a reopened account.

        Support tickets are kept for 3 years. Attachments on support tickets are deleted after 90 days unless the ticket is still open.

        Any exception to these periods needs written approval from legal and must be recorded in the retention register.
        """
      },
      %{
        id: "bl-spec-06",
        mode: :linguistic,
        genre: "spec",
        text: ~S"""
        CSV export for the invoices page

        Users can export the invoices they are currently looking at, with filters applied, as a CSV file.

        Columns, in this order: invoice number, customer, issue date, due date, amount, currency, status. Dates use ISO format. Amounts use a dot as the decimal separator regardless of the user's locale, since the file is mostly opened by accountants who import it into other tools.

        Exports over 10,000 rows run in the background and the user gets an email with a download link that expires after 24 hours. Smaller exports download immediately.

        We are not building import in this project. The file format should still be stable enough that we could import it back later.
        """
      },

      # ------------------------------------------------------------------
      # Decision logs
      # ------------------------------------------------------------------
      %{
        id: "bl-decision-01",
        mode: :linguistic,
        genre: "decision-log",
        text: ~S"""
        # ADR 014: Keep background jobs in the main database

        Status: Accepted
        Date: 2026-02-18

        ## Context
        Our job queue lives in the same database as the application data. We discussed moving it to a dedicated message broker because job volume has grown about 4x this year.

        ## Decision
        We will keep jobs in the main database for now and add a separate connection pool for the workers.

        ## Consequences
        - No new infrastructure to run, monitor and pay for.
        - Enqueueing a job stays transactional with the data change that caused it, which removes a whole class of bugs.
        - We accept higher load on the primary. We will revisit if job inserts exceed 300 per second sustained or if worker queries show up in the top ten slow queries.
        """
      },
      %{
        id: "bl-decision-02",
        mode: :linguistic,
        genre: "decision-log",
        text: ~S"""
        Decision log, website relaunch

        2026-01-09 - Agreed to drop the blog from the relaunch scope. Posts stay on the old site until we migrate them separately. (Ruth, Sam, Ola)
        2026-01-16 - Chose the two-column homepage layout over the video hero. Video tested worse on mobile load time.
        2026-01-23 - Contact form submissions will go to the shared inbox, not individual people. Reason: coverage during holidays.
        2026-02-02 - Partly reversed the 01-09 decision: the five most visited posts move with the relaunch.
        """
      },
      %{
        id: "bl-decision-03",
        mode: :linguistic,
        genre: "decision-log",
        text: ~S"""
        Decision: we are dropping support for browsers older than two major versions, starting with the June release.

        Why: about 0.8% of sessions last quarter came from those browsers, and roughly a third of our front-end bug reports were specific to them. Supporting them also blocks us from using several layout features the design team has been asking for.

        What it means: users on older browsers will see a banner asking them to update. The app will keep loading for them, but we won't test against those versions or fix issues that only happen there.

        Who decided: product and engineering leads, with sign-off from support after we agreed on the banner wording.

        Revisit: if the share of affected sessions goes above 2%.
        """
      },
      %{
        id: "bl-decision-04",
        mode: :linguistic,
        genre: "decision-log",
        text: ~S"""
        Decision record: one repository for the web app and the mobile app

        We considered three options: keep two repositories, move to one repository with shared packages, or extract only the shared logic into a third repository.

        We chose the single repository. The main reason is that most features touch both apps, and today that means two pull requests, two reviews and a coordination step that people forget. A third repository would have kept the coordination problem and added a publishing step on top.

        The cost we accept is a slower pipeline for everyone. We will mitigate it by running only the affected app's tests on each change.

        Decided on 4 March by the platform group. Andre owns the migration.
        """
      },

      # ------------------------------------------------------------------
      # Standups
      # ------------------------------------------------------------------
      %{
        id: "bl-standup-01",
        mode: :linguistic,
        genre: "standup",
        text: ~S"""
        Yesterday: finished the date picker fixes and got them reviewed. Paired with Ola on the flaky upload test, we think it's a timing issue with the mock server.
        Today: merge the date picker, then write the migration for the new reminder fields.
        Blockers: need someone with admin rights to create the staging bucket. Asked in the ops channel, no answer yet.
        """
      },
      %{
        id: "bl-standup-02",
        mode: :linguistic,
        genre: "standup",
        text: ~S"""
        Async standup, Wednesday

        Kemal
        - done: invoice PDF layout, both languages
        - next: totals rounding bug
        - blocked: no

        Sofia
        - done: interviews with two pilot customers, notes in the research folder
        - next: synthesis doc for Friday
        - blocked: waiting on the third customer to confirm a time

        Dmitri
        - done: nothing shippable, deep in the search index rebuild
        - next: same, hoping to finish tomorrow
        - blocked: no, but it's bigger than I estimated
        """
      },
      %{
        id: "bl-standup-03",
        mode: :linguistic,
        genre: "standup",
        text:
          "y: on-call, two pages, both the disk alert on the reports box. t: write up the disk issue and pick up the export ticket. b: none"
      },
      %{
        id: "bl-standup-04",
        mode: :linguistic,
        genre: "standup",
        text: ~S"""
        Quick update since I'll miss the call:
        - Shipped the refactor of the PaymentForm component. No visual changes, just split it into three pieces.
        - Started on the saved cards work. The design is final, the backend endpoint isn't ready so I'm building against a stub.
        - Nothing blocking right now. Out tomorrow afternoon for an appointment.
        """
      },
      %{
        id: "bl-standup-05",
        mode: :linguistic,
        genre: "standup",
        text: ~S"""
        Morning check-in, site B
        Done yesterday: second floor drywall finished, electrical inspection passed.
        Today: start priming the second floor, kitchen cabinet delivery expected around 10.
        Issues: the back stairwell light is still out, someone please bring a ladder. Also we're short two people because of the flu.
        """
      },

      # ------------------------------------------------------------------
      # Postmortems
      # ------------------------------------------------------------------
      %{
        id: "bl-postmortem-01",
        mode: :linguistic,
        genre: "postmortem",
        text: ~S"""
        # Incident review: checkout errors on 14 May

        ## Summary
        For 47 minutes, about 30% of checkout attempts failed with a generic error. No payments were taken twice and no orders were lost, but customers had to retry.

        ## Impact
        Roughly 1,900 failed attempts. Support received 140 contacts. We estimate 300 to 400 customers did not retry.

        ## Timeline (UTC)
        - 13:02 Deploy of the address validation change.
        - 13:09 Error rate alert fires. On-call acknowledges.
        - 13:25 Errors traced to the new validation calling a slow external lookup.
        - 13:41 Decision to roll back rather than patch.
        - 13:49 Rollback complete, errors back to baseline.

        ## Root cause
        The new validation made a synchronous call with a 30 second timeout. Under normal load it was fine; at lunchtime traffic the calls piled up and exhausted the worker pool.

        ## What went well
        Alerting fired within 7 minutes and the rollback was clean.

        ## Action items
        - Add a 2 second timeout and a fallback to the lookup (Ines, 21 May).
        - Load test any change that adds an external call to checkout (team, ongoing).
        - Make rollback the default first step when an incident follows a deploy (Mark, update runbook by 20 May).
        """
      },
      %{
        id: "bl-postmortem-02",
        mode: :linguistic,
        genre: "postmortem",
        text: ~S"""
        What happened: the nightly report emails went out with last month's numbers on 3 and 4 June.

        Why: the report job reads from a summary table that is refreshed by a separate job. The refresh job was moved to a new schedule during the server maintenance and ended up running after the report instead of before it. Nothing failed, so nothing alerted.

        What we changed: the report job now checks the refresh timestamp and refuses to send if the data is older than 6 hours. It pages instead.

        What we'd still like to do: put both jobs in a single pipeline so the order is explicit rather than based on clock times.
        """
      },
      %{
        id: "bl-postmortem-03",
        mode: :linguistic,
        genre: "postmortem",
        text: ~S"""
        Retrospective: the spring catalogue launch slipped by three weeks

        The catalogue was planned for 1 March and went out on 22 March. Nobody did anything wrong in isolation; the delay came from three small things stacking up.

        First, the photo shoot was rebooked twice because of the weather, and we had no indoor backup. Second, the copy review needed sign-off from four people, and two of them were travelling. Third, the printer needed final files ten days earlier than we had assumed, which nobody had confirmed in writing.

        For the autumn catalogue we will book an indoor studio as a fallback, reduce copy sign-off to two people with the others informed, and get the printer's deadlines confirmed at kickoff. Bea will own the schedule end to end, rather than each team keeping its own.
        """
      },
      %{
        id: "bl-postmortem-04",
        mode: :linguistic,
        genre: "postmortem",
        text: ~S"""
        Postmortem: login outage, 2026-08-02

        Duration: 22:14 to 23:03 UTC (49 min)
        Severity: SEV-2
        Author: Yusuf

        Timeline
        22:14 Certificate on the identity service expires. All new logins fail.
        22:19 First customer report via chat.
        22:31 On-call paged after error budget alert. 17 minutes after start, too slow.
        22:40 Cause identified.
        22:58 New certificate issued and deployed.
        23:03 Logins confirmed working from three regions.

        Contributing factors
        The renewal reminder went to a shared inbox that was retired in the spring. The automated renewal for this certificate had been disabled during a migration and never turned back on.

        Follow-ups
        1. Audit every certificate for automated renewal, owner: Yusuf, due 9 Aug.
        2. Alert on any certificate expiring within 14 days, owner: Grace, due 16 Aug.
        3. Page directly on login failure rate, not only on the error budget, owner: Grace, due 16 Aug.
        """
      },

      # ------------------------------------------------------------------
      # Runbooks
      # ------------------------------------------------------------------
      %{
        id: "bl-runbook-01",
        mode: :linguistic,
        genre: "runbook",
        text: ~S"""
        Runbook: queue depth alarm on the email sender

        When it fires: the number of unsent emails has been above 5,000 for 10 minutes.

        1. Open the email sender dashboard and check whether the send rate dropped to zero or is just slower than usual.
        2. If the send rate is zero, check the provider status page. If the provider is having an incident, post in the incidents channel and wait; do not restart anything.
        3. If the provider is fine, restart the sender workers from the admin console, one at a time, waiting a minute between each.
        4. If the queue is still growing after all workers are restarted, page the secondary on-call.
        5. Once the queue drains below 500, resolve the alarm and add a short note to the on-call log.

        Do not purge the queue. Purged emails cannot be recovered, and some of them are password resets.
        """
      },
      %{
        id: "bl-runbook-02",
        mode: :linguistic,
        genre: "runbook",
        text: ~S"""
        New starter laptop handover

        Two days before the start date
        - Pick a laptop from the ready shelf and check the sticker says "wiped and imaged".
        - Log in with the setup account, connect to the office wifi and let updates finish. This can take an hour, start it in the morning.
        - Create the person's account using their work email, set a temporary password and tick "must change at next login".

        On the first day
        - Hand over the laptop, charger and a printed sheet with the temporary password.
        - Sit with them while they change the password and enroll the second factor on their phone.
        - Show them where the printer guide and the help desk form are.

        If anything fails, don't improvise. Log a ticket and give them a loaner from the second shelf.
        """
      },
      %{
        id: "bl-runbook-03",
        mode: :linguistic,
        genre: "runbook",
        text: ~S"""
        Disk usage above 90% on a worker node

        First, find out what is growing. Usually it's one of three things: application logs that stopped rotating, temporary export files that weren't cleaned up, or the local image cache.

        If it's logs, check in the system journal whether log rotation ran last night. If it didn't, rotate manually through the ops console and open a ticket for the rotation failure.

        If it's export files, anything older than 24 hours in the exports directory is safe to delete. Anything newer may still be downloading, so leave it.

        If it's the image cache, drain the node from the scheduler first, then prune the cache, then return the node to service.

        If usage is above 97% and climbing quickly, drain the node immediately before investigating. A full disk on these nodes corrupts the job journal.
        """
      },

      # ------------------------------------------------------------------
      # Plans
      # ------------------------------------------------------------------
      %{
        id: "bl-plan-01",
        mode: :linguistic,
        genre: "plan",
        text: ~S"""
        Q3 plan, customer success

        Objective 1: cut time to first value for new accounts
        - Replace the 60 minute onboarding call with a 20 minute call plus a guided checklist.
        - Target: 70% of new accounts complete setup within 7 days (today it's 48%).

        Objective 2: reduce churn in accounts under 10 seats
        - Introduce a check-in at day 45, where we see most small accounts go quiet.
        - Build a simple health score from logins and invites; flag anything red to the account owner weekly.

        Objective 3: make the team less dependent on two people
        - Document the top 15 support questions.
        - Everyone shadows a renewal conversation before the end of August.

        Not doing this quarter: a customer community forum. Revisit in Q4.
        """
      },
      %{
        id: "bl-plan-02",
        mode: :linguistic,
        genre: "plan",
        text: ~S"""
        Plan for moving file storage to the new provider

        Phase 1, weeks 1-2: dual write. Every new upload goes to both the old and new storage. Reads still come from the old one. We watch for errors and compare checksums on a sample.

        Phase 2, weeks 3-5: backfill. Copy existing files in batches, oldest first, at night. Track progress per workspace so we can pause and resume safely.

        Phase 3, week 6: switch reads. Start with internal workspaces, then 10% of customers, then everyone over three days. If error rates rise, flip back; dual write means nothing is lost.

        Phase 4, week 8: stop writing to the old storage. Keep it read-only for 30 days, then delete.

        Dependencies: the security review of the new provider must be signed off before phase 1 starts. Finance needs two weeks' notice before phase 4 to cancel the old contract.
        """
      },
      %{
        id: "bl-plan-03",
        mode: :linguistic,
        genre: "plan",
        text: ~S"""
        Team offsite, rough plan

        When: 15-17 October, arriving the evening of the 14th
        Where: the lodge we used two years ago, if they have space. Backup is the conference hotel in town.
        Who: the whole team plus Ravi and Mo from the partner team for day two.

        Day 1: strategy morning, afternoon free, dinner together.
        Day 2: workshops on the roadmap and on how we work with the partner team.
        Day 3: half day, wrap-up and travel home.

        Budget: about 9,000 for travel, rooms and food. Activities beyond dinner are optional and on a sign-up basis.

        Next steps: Hana confirms the venue by Friday, then I'll send the calendar invite and the travel form.
        """
      },
      %{
        id: "bl-plan-04",
        mode: :linguistic,
        genre: "plan",
        text: ~S"""
        Launch plan for the mobile app redesign

        Four weeks out: freeze features. Only bug fixes after this point. Marketing starts drafting the announcement.
        Three weeks out: open the beta to 500 existing users who opted in. Support gets a walkthrough and an FAQ draft.
        Two weeks out: review beta feedback, fix the top issues, go or no-go decision on the 12th.
        One week out: submit to the app stores. Prepare the help center articles and screenshots.
        Launch day: release to 10% of users in the morning, 50% if crash rates hold, everyone the next day.
        After launch: daily triage of reviews and support tickets for two weeks, then back to the normal rhythm.

        Owner: Laila. Escalations go to her first.
        """
      },

      # ------------------------------------------------------------------
      # Briefs
      # ------------------------------------------------------------------
      %{
        id: "bl-brief-01",
        mode: :linguistic,
        genre: "brief",
        text: ~S"""
        Creative brief: winter membership campaign

        Background
        Membership sign-ups drop by about 40% between November and February. Last winter's campaign focused on discounts and barely moved the number.

        Objective
        Grow winter sign-ups by 15% compared to last year without discounting below the standard rate.

        Audience
        Adults 25 to 45 within a 20 minute commute who visited at least once in the summer but didn't join.

        Key message
        The pool is warm and empty in January. This is the best time of year to start.

        Tone
        Calm, a little playful, never guilt-tripping about new year resolutions.

        Deliverables
        Two posters, a short email sequence and three social posts. Drafts due 20 October.
        """
      },
      %{
        id: "bl-brief-02",
        mode: :linguistic,
        genre: "brief",
        text: ~S"""
        Brief for the leadership meeting on Thursday

        The ask: approve hiring two additional support agents now instead of in January.

        Why now: ticket volume is up 35% since the summer launch, first response time has gone from 3 hours to 11, and our satisfaction score dropped from 91 to 84 in six weeks. Two senior agents are close to burnout and one has mentioned leaving.

        Cost: about 18,000 for the remainder of the year, which we can cover from the unspent events budget.

        Risk if we wait: response times keep sliding through the busiest period, and we likely lose at least one experienced agent, which would take months to replace.

        Recommendation: approve both roles this week so offers can go out before the end of the month.
        """
      },
      %{
        id: "bl-brief-03",
        mode: :linguistic,
        genre: "brief",
        text: ~S"""
        Research brief: why trial users don't invite teammates

        What we want to learn: why fewer than a quarter of trial users invite anyone, even though accounts with two or more people convert at three times the rate.

        Questions
        - Do people understand the product is meant for teams?
        - Is the invite step hard to find, or do they find it and choose not to use it?
        - Is there a social cost to inviting colleagues to something you haven't decided on yet?

        Method: 8 to 10 interviews with trial users from the last 60 days, half who invited someone and half who didn't. 30 minutes each, remote.

        Timeline: recruiting this week, interviews next week, readout on the 28th.

        Who: Noor leads, with Ben observing at least three sessions.
        """
      },

      # ------------------------------------------------------------------
      # Changelogs
      # ------------------------------------------------------------------
      %{
        id: "bl-changelog-01",
        mode: :linguistic,
        genre: "changelog",
        text: ~S"""
        # Changelog

        ## [2.4.0] - 2026-03-02

        ### Added
        - `parseDate()` now accepts week dates such as `2026-W09-1`.
        - New `strict` option that makes parsing fail on ambiguous input instead of guessing.

        ### Changed
        - Default output time zone is now UTC instead of the system zone.

        ### Fixed
        - Leap seconds no longer cause an off-by-one in `diffSeconds()`.
        - Parsing no longer throws on empty strings; it returns `null`.

        ## [2.3.1] - 2026-01-19

        ### Fixed
        - Typo in the error message for invalid months.
        """
      },
      %{
        id: "bl-changelog-02",
        mode: :linguistic,
        genre: "changelog",
        text: ~S"""
        Release notes, version 5.2

        This release is mostly about speed. Large projects now open about twice as fast, because we load the task list in pages instead of all at once. If you have a project with thousands of tasks, you'll notice it most.

        You can now pin up to five projects to the top of the sidebar. Pinned projects stay in the order you put them, even when others are updated.

        We fixed the bug where comments written offline sometimes appeared twice once you reconnected, and the one where the due date picker skipped February 29.

        Finally, the old export format is gone. If you were still using it, the new format has the same columns plus attachments.
        """
      },
      %{
        id: "bl-changelog-03",
        mode: :linguistic,
        genre: "changelog",
        text: ~S"""
        v1.8.3 (2026-06-11)
        * fix: crash when the config file is empty
        * fix: progress bar overflowing on narrow terminals

        v1.8.2 (2026-05-30)
        * docs: clarify how to set the cache directory
        * chore: bump the minimum supported runtime version

        v1.8.1 (2026-05-21)
        * fix: `--quiet` flag was ignored by the sync command
        """
      },

      # ------------------------------------------------------------------
      # Context-free short replies (linguistic, no genre)
      # ------------------------------------------------------------------
      %{id: "bl-short-01", mode: :linguistic, genre: nil, text: "ok"},
      %{id: "bl-short-02", mode: :linguistic, genre: nil, text: "thanks!"},
      %{id: "bl-short-03", mode: :linguistic, genre: nil, text: "+1"},
      %{id: "bl-short-04", mode: :linguistic, genre: nil, text: "sounds good"},
      %{id: "bl-short-05", mode: :linguistic, genre: nil, text: "will do"},
      %{id: "bl-short-06", mode: :linguistic, genre: nil, text: "np"},

      # ------------------------------------------------------------------
      # Mixed: prose plus a substantive code block, table or image
      # ------------------------------------------------------------------
      %{
        id: "bl-mixed-01",
        mode: :mixed,
        genre: "email",
        text: ~S"""
        Subject: Help with the monthly churn query?

        Hi Omar,

        Could you sanity check the query below before I put the number in the board deck? It returns 4.1% for September, which feels low compared to what the support team is seeing.

        ```sql
        SELECT
          date_trunc('month', cancelled_at) AS month,
          count(*) FILTER (WHERE cancelled_at IS NOT NULL)::float
            / count(*) AS churn_rate
        FROM subscriptions
        WHERE started_at < date '2026-09-01'
        GROUP BY 1
        ORDER BY 1;
        ```

        My worry is that the denominator includes everyone who ever subscribed, not just people active at the start of the month. If that's right, how would you fix it?

        Thanks a lot,
        Bea
        """
      },
      %{
        id: "bl-mixed-02",
        mode: :mixed,
        genre: "message",
        text: ~S"""
        can someone tell me why this prints the same list three times? I expected three different ones

        ```python
        rows = [[]] * 3
        rows[0].append("a")
        print(rows)
        ```

        I get [['a'], ['a'], ['a']] and I'm losing my mind
        """
      },
      %{
        id: "bl-mixed-03",
        mode: :mixed,
        genre: "message",
        text: ~S"""
        @Omar the backup job is failing on the new box. this is what I ran:

        ```bash
        sudo systemctl status nightly-backup
        journalctl -u nightly-backup --since "1 hour ago" | tail -n 20
        ```

        it says permission denied on the target folder. did the mount options change when you rebuilt it? I don't want to chmod things blindly
        """
      },
      %{
        id: "bl-mixed-04",
        mode: :mixed,
        genre: "note",
        text: ~S"""
        Whiteboard from the Thursday session, before someone erases it:

        ![whiteboard sketch of the new checkout steps](images/whiteboard-checkout-2026-03-05.jpg)

        Main points we landed on: the address step and the shipping step become one screen, the promo code moves to the cart, and guest checkout is the default. Kim is turning this into wireframes next week.
        """
      },
      %{
        id: "bl-mixed-05",
        mode: :mixed,
        genre: "note",
        text: ~S"""
        Note to self for when the laptop gets rebuilt again. The dev certs live in the vault, not on disk. To get local https working:

        ```sh
        mkdir -p ~/.local/certs
        cp /mnt/vault/dev/local-dev.pem ~/.local/certs/
        export DEV_CERT_PATH=~/.local/certs/local-dev.pem
        ./scripts/start-dev --https
        ```

        If the browser still complains, it's the system trust store, not the app. Don't waste an hour on it like last time.
        """
      },
      %{
        id: "bl-mixed-06",
        mode: :mixed,
        genre: "spec",
        text: ~S"""
        ## Role permissions for shared calendars

        Each calendar has three roles. A person can hold only one role per calendar. Owners can change anyone's role except their own, so a calendar always has at least one owner.

        | Action              | Viewer | Editor | Owner |
        |---------------------|--------|--------|-------|
        | See events          | yes    | yes    | yes   |
        | Create events       | no     | yes    | yes   |
        | Delete any event    | no     | no     | yes   |
        | Invite people       | no     | yes    | yes   |
        | Change roles        | no     | no     | yes   |

        Editors can delete events they created themselves. Viewers who are invited to an event can still respond to it, which does not count as editing.
        """
      },
      %{
        id: "bl-mixed-07",
        mode: :mixed,
        genre: "spec",
        text: ~S"""
        ### POST /v1/reminders

        Creates a reminder for the authenticated user. The time is interpreted in the user's profile time zone unless an explicit offset is included.

        Request body:

        ```json
        {
          "title": "Send the signed lease",
          "remind_at": "2026-05-02T09:00:00",
          "channels": ["push", "email"]
        }
        ```

        Responses:
        - 201 with the created reminder, including its `id`.
        - 422 if `remind_at` is in the past or `channels` is empty.
        - 429 if the user already has 500 active reminders.

        Reminders are not editable after they fire. To repeat a reminder, create a new one.
        """
      },
      %{
        id: "bl-mixed-08",
        mode: :mixed,
        genre: "decision-log",
        text: ~S"""
        ## Decision: which provider runs the new phone support line

        We shortlisted three providers after the January demos. Scores are out of 5, agreed in the 12 Feb review.

        | Criterion            | Provider A | Provider B | Provider C |
        |----------------------|-----------:|-----------:|-----------:|
        | Call quality         | 4          | 5          | 3          |
        | Monthly cost         | 3          | 2          | 5          |
        | Reporting            | 5          | 4          | 2          |
        | Contract flexibility | 4          | 3          | 4          |

        **Decision:** Provider A. B was better on call quality, but the cost difference over a two-year term is larger than the support budget increase we have. C was cheapest, but its reporting would mean building our own dashboards.

        **Review date:** after the first full quarter of use.
        """
      },
      %{
        id: "bl-mixed-09",
        mode: :mixed,
        genre: "postmortem",
        text: ~S"""
        ## Root cause

        The rate limiter for the public API was configured per instance rather than globally. When we scaled from 4 to 12 instances during the sale, the effective limit tripled and the database took the extra load. This is the change that shipped on Monday:

        ```diff
         rate_limit:
        -  scope: global
        -  requests_per_minute: 6000
        +  scope: instance
        +  requests_per_minute: 1500
           burst: 200
        ```

        The reviewer saw the numbers go down and reasonably assumed it was stricter. Nothing in the file explains that `instance` multiplies by the number of running instances.

        ## Follow-up
        We're renaming the option to make the scope explicit and adding a startup log line that prints the effective global limit.
        """
      },
      %{
        id: "bl-mixed-10",
        mode: :mixed,
        genre: "runbook",
        text: ~S"""
        ## Rotating the API signing key

        Do this during business hours, with a second person watching.

        1. Generate the new key pair on the bastion host:

        ```bash
        ./ops/keytool generate --type ed25519 --out signing-new.pem
        ./ops/keytool public --in signing-new.pem --out signing-new.pub
        ```

        2. Add the new public key to the verifier config alongside the old one, deploy, and wait until every instance reports both keys:

        ```bash
        ./ops/check-keys --env production --expect 2
        ```

        3. Switch the signer to the new key and deploy.
        4. After 48 hours, remove the old public key and deploy once more.

        If step 2 reports fewer than two keys on any instance, stop and do not continue to step 3.
        """
      },
      %{
        id: "bl-mixed-11",
        mode: :mixed,
        genre: "runbook",
        text: ~S"""
        Runbook: unlocking a customer account after too many failed logins

        Support can unlock accounts from the admin panel. Use this procedure only when the admin panel is unavailable.

        Confirm the customer's identity using the usual two questions before doing anything. Then connect to the primary with your personal database account (never the shared one) and run:

        ```sql
        UPDATE accounts
        SET failed_logins = 0,
            locked_until = NULL
        WHERE email = 'customer@example.com'
          AND locked_until IS NOT NULL;
        ```

        The statement should report exactly one updated row. If it reports zero, the account wasn't locked; if more than one, roll back immediately and escalate.

        Record the ticket number and the time in the access log spreadsheet.
        """
      },
      %{
        id: "bl-mixed-12",
        mode: :mixed,
        genre: "plan",
        text: ~S"""
        # Warehouse scanner rollout plan

        We'll roll out the new handheld scanners one site at a time so that each site can lean on the previous one for help. Training happens the week before each go-live, never the same week.

        | Site      | Training week | Go-live | Site lead |
        |-----------|---------------|---------|-----------|
        | North     | 6 Apr         | 13 Apr  | Hugo      |
        | Riverside | 20 Apr        | 27 Apr  | Asha      |
        | East      | 4 May         | 11 May  | Pete      |
        | Harbor    | 18 May        | 25 May  | Lina      |

        Go or no-go for each site is decided on the Thursday before go-live, based on whether at least 90% of staff on that site have completed training. If a site slips, the next site keeps its date; we don't let delays cascade.
        """
      },

      # ------------------------------------------------------------------
      # Code
      # ------------------------------------------------------------------
      %{
        id: "bl-code-01",
        mode: :code,
        genre: nil,
        text: ~S"""
        from dataclasses import dataclass
        from datetime import date


        @dataclass(frozen=True)
        class Booking:
            guest: str
            check_in: date
            check_out: date

            @property
            def nights(self) -> int:
                return (self.check_out - self.check_in).days


        def overlapping(a: Booking, b: Booking) -> bool:
            return a.check_in < b.check_out and b.check_in < a.check_out


        def find_conflicts(bookings: list[Booking]) -> list[tuple[Booking, Booking]]:
            ordered = sorted(bookings, key=lambda b: b.check_in)
            conflicts = []
            for i, current in enumerate(ordered):
                for other in ordered[i + 1:]:
                    if other.check_in >= current.check_out:
                        break
                    conflicts.append((current, other))
            return conflicts
        """
      },
      %{
        id: "bl-code-02",
        mode: :code,
        genre: nil,
        text: ~S"""
        defmodule Inventory.Counter do
          use GenServer

          def start_link(opts) do
            GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
          end

          def reserve(server \\ __MODULE__, sku, qty) when qty > 0 do
            GenServer.call(server, {:reserve, sku, qty})
          end

          def restock(server \\ __MODULE__, sku, qty) do
            GenServer.cast(server, {:restock, sku, qty})
          end

          @impl true
          def init(state), do: {:ok, state}

          @impl true
          def handle_call({:reserve, sku, qty}, _from, state) do
            available = Map.get(state, sku, 0)

            if available >= qty do
              {:reply, :ok, Map.put(state, sku, available - qty)}
            else
              {:reply, {:error, :insufficient, available}, state}
            end
          end

          @impl true
          def handle_cast({:restock, sku, qty}, state) do
            {:noreply, Map.update(state, sku, qty, &(&1 + qty))}
          end
        end
        """
      },
      %{
        id: "bl-code-03",
        mode: :code,
        genre: nil,
        text: ~S"""
        const form = document.querySelector("#signup");
        const email = form.querySelector("input[name=email]");
        const hint = document.querySelector("#email-hint");

        function isValidEmail(value) {
          return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim());
        }

        email.addEventListener("input", () => {
          const ok = isValidEmail(email.value);
          hint.textContent = ok ? "" : "That doesn't look like an email address yet.";
          form.querySelector("button").disabled = !ok;
        });

        form.addEventListener("submit", async (event) => {
          event.preventDefault();
          const res = await fetch("/api/signup", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ email: email.value.trim() }),
          });
          if (!res.ok) {
            hint.textContent = "Something went wrong, please try again.";
            return;
          }
          window.location.assign("/welcome");
        });
        """
      },
      %{
        id: "bl-code-04",
        mode: :code,
        genre: nil,
        text: ~S"""
        export type Money = { amount: number; currency: "EUR" | "USD" | "GBP" };

        export interface LineItem {
          sku: string;
          quantity: number;
          unitPrice: Money;
        }

        export function orderTotal(items: readonly LineItem[]): Money {
          if (items.length === 0) {
            throw new Error("cannot total an empty order");
          }
          const currency = items[0].unitPrice.currency;
          const cents = items.reduce((sum, item) => {
            if (item.unitPrice.currency !== currency) {
              throw new Error(`mixed currencies: ${currency} and ${item.unitPrice.currency}`);
            }
            return sum + Math.round(item.unitPrice.amount * 100) * item.quantity;
          }, 0);
          return { amount: cents / 100, currency };
        }
        """
      },
      %{
        id: "bl-code-05",
        mode: :code,
        genre: nil,
        text: ~S"""
        CREATE TABLE room_bookings (
            id           BIGSERIAL PRIMARY KEY,
            room_id      INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
            booked_by    INTEGER NOT NULL REFERENCES members(id),
            starts_at    TIMESTAMPTZ NOT NULL,
            ends_at      TIMESTAMPTZ NOT NULL,
            purpose      TEXT,
            created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
            CHECK (ends_at > starts_at)
        );

        CREATE INDEX room_bookings_room_time_idx
            ON room_bookings (room_id, starts_at);

        COMMENT ON TABLE room_bookings IS 'One row per reservation of a meeting room.';
        """
      },
      %{
        id: "bl-code-06",
        mode: :code,
        genre: nil,
        text: ~S"""
        WITH monthly AS (
          SELECT
            customer_id,
            date_trunc('month', paid_at) AS month,
            sum(amount_cents) AS revenue
          FROM payments
          WHERE status = 'settled'
          GROUP BY customer_id, date_trunc('month', paid_at)
        ),
        ranked AS (
          SELECT *,
                 rank() OVER (PARTITION BY month ORDER BY revenue DESC) AS position
          FROM monthly
        )
        SELECT month, customer_id, revenue / 100.0 AS revenue
        FROM ranked
        WHERE position <= 10
        ORDER BY month DESC, position;
        """
      },
      %{
        id: "bl-code-07",
        mode: :code,
        genre: nil,
        text: ~S"""
        #!/usr/bin/env bash
        set -euo pipefail

        # Archive yesterday's upload logs and keep the last 30 archives.
        LOG_DIR="/var/log/uploader"
        ARCHIVE_DIR="/var/backups/uploader"
        DAY="$(date -d yesterday +%F)"

        mkdir -p "$ARCHIVE_DIR"

        shopt -s nullglob
        files=("$LOG_DIR"/upload-"$DAY"*.log)
        if (( ${#files[@]} == 0 )); then
          echo "no logs for $DAY, nothing to do"
          exit 0
        fi

        tar -czf "$ARCHIVE_DIR/upload-$DAY.tar.gz" "${files[@]}"
        rm -f -- "${files[@]}"

        ls -1t "$ARCHIVE_DIR"/upload-*.tar.gz | tail -n +31 | xargs -r rm -f --
        echo "archived ${#files[@]} files for $DAY"
        """
      },
      %{
        id: "bl-code-08",
        mode: :code,
        genre: nil,
        text: ~S"""
        FROM python:3.12-slim AS build
        WORKDIR /app
        COPY requirements.txt .
        RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

        FROM python:3.12-slim
        ENV PYTHONUNBUFFERED=1 \
            PORT=8080
        RUN useradd --create-home --uid 10001 app
        WORKDIR /app
        COPY --from=build /install /usr/local
        COPY . .
        USER app
        EXPOSE 8080
        HEALTHCHECK --interval=30s --timeout=3s CMD python -m app.healthcheck
        CMD ["python", "-m", "app.server"]
        """
      },
      %{
        id: "bl-code-09",
        mode: :code,
        genre: nil,
        text: ~S"""
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Opening hours</title>
          <link rel="stylesheet" href="/css/site.css">
        </head>
        <body>
          <main class="hours">
            <h1>Opening hours</h1>
            <table>
              <tr><th scope="row">Monday to Friday</th><td>8:00 to 18:00</td></tr>
              <tr><th scope="row">Saturday</th><td>9:00 to 14:00</td></tr>
              <tr><th scope="row">Sunday</th><td>Closed</td></tr>
            </table>
            <p class="note">Holiday hours are posted two weeks in advance.</p>
            <a class="button" href="/contact">Get in touch</a>
          </main>
        </body>
        </html>
        """
      },
      %{
        id: "bl-code-10",
        mode: :code,
        genre: nil,
        text: ~S"""
        :root {
          --ink: #1d1f24;
          --paper: #fbfaf7;
          --accent: #c2410c;
          --radius: 10px;
        }

        .card {
          background: var(--paper);
          color: var(--ink);
          border-radius: var(--radius);
          padding: 1.25rem 1.5rem;
          box-shadow: 0 1px 2px rgb(0 0 0 / 0.06), 0 4px 12px rgb(0 0 0 / 0.04);
        }

        .card__title {
          font-size: 1.125rem;
          font-weight: 600;
          margin: 0 0 0.5rem;
        }

        .card a:hover,
        .card a:focus-visible {
          color: var(--accent);
          text-decoration-thickness: 2px;
        }

        @media (max-width: 600px) {
          .card { padding: 1rem; }
        }
        """
      },
      %{
        id: "bl-code-11",
        mode: :code,
        genre: nil,
        text: ~S"""
        variable "environment" {
          type    = string
          default = "staging"
        }

        locals {
          name_prefix = "orders-${var.environment}"
          is_prod     = var.environment == "production"
        }

        resource "examplecloud_bucket" "uploads" {
          name       = "${local.name_prefix}-uploads"
          versioning = local.is_prod

          lifecycle_rule {
            prefix      = "tmp/"
            expire_days = 7
          }
        }

        resource "examplecloud_instance_group" "workers" {
          name          = "${local.name_prefix}-workers"
          instance_size = local.is_prod ? "large" : "small"
          min_count     = local.is_prod ? 3 : 1
          max_count     = local.is_prod ? 12 : 2
        }

        output "uploads_bucket" {
          value = examplecloud_bucket.uploads.name
        }
        """
      },
      %{
        id: "bl-code-12",
        mode: :code,
        genre: nil,
        text: ~S"""
        package api

        import (
        	"encoding/json"
        	"net/http"
        	"strconv"
        )

        type Store interface {
        	Item(id int64) (*Item, error)
        }

        type Item struct {
        	ID    int64  `json:"id"`
        	Title string `json:"title"`
        	Done  bool   `json:"done"`
        }

        func ItemHandler(store Store) http.HandlerFunc {
        	return func(w http.ResponseWriter, r *http.Request) {
        		id, err := strconv.ParseInt(r.URL.Query().Get("id"), 10, 64)
        		if err != nil {
        			http.Error(w, "invalid id", http.StatusBadRequest)
        			return
        		}
        		item, err := store.Item(id)
        		if err != nil {
        			http.Error(w, "not found", http.StatusNotFound)
        			return
        		}
        		w.Header().Set("Content-Type", "application/json")
        		_ = json.NewEncoder(w).Encode(item)
        	}
        }
        """
      },
      %{
        id: "bl-code-13",
        mode: :code,
        genre: nil,
        text: ~S"""
        use std::collections::HashMap;

        #[derive(Debug, Default)]
        pub struct WordCount {
            counts: HashMap<String, usize>,
        }

        impl WordCount {
            pub fn add_text(&mut self, text: &str) {
                for word in text
                    .split(|c: char| !c.is_alphanumeric() && c != '\'')
                    .filter(|w| !w.is_empty())
                {
                    *self.counts.entry(word.to_lowercase()).or_insert(0) += 1;
                }
            }

            pub fn top(&self, n: usize) -> Vec<(&str, usize)> {
                let mut pairs: Vec<_> = self.counts.iter().map(|(w, c)| (w.as_str(), *c)).collect();
                pairs.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
                pairs.truncate(n);
                pairs
            }
        }
        """
      },
      %{
        id: "bl-code-14",
        mode: :code,
        genre: nil,
        text: ~S"""
        import sys
        print(" ".join(reversed(sys.argv[1:])))
        """
      },
      %{
        id: "bl-code-15",
        mode: :code,
        genre: nil,
        text: ~S"""
        const add = (a, b) => a + b;
        export default add;
        """
      },
      %{
        id: "bl-code-16",
        mode: :code,
        genre: nil,
        text: ~S"""
        /*
         * ring.c - fixed size ring buffer used by the sensor reader.
         *
         * The reader interrupt writes samples here and the main loop drains
         * them. There is exactly one writer and one reader, so no locking is
         * needed as long as head and tail are only written by their owner.
         *
         * Capacity must be a power of two so we can mask instead of using
         * the modulo operator, which is slow on this chip.
         *
         * If you change RING_SIZE, also update the test in test_ring.c,
         * which assumes it.
         */

        #include "ring.h"

        /* Returns 1 if a sample was stored, 0 if the buffer was full. */
        int ring_push(struct ring *r, uint16_t sample)
        {
            if (r->head - r->tail == RING_SIZE)
                return 0;
            r->buf[r->head & (RING_SIZE - 1)] = sample;
            r->head++;
            return 1;
        }
        """
      },
      %{
        id: "bl-code-17",
        mode: :code,
        genre: nil,
        text: ~S"""
        class LateFeeCalculator
          GRACE_DAYS = 5
          DAILY_RATE = 0.0015
          MAX_FEE_RATIO = 0.1

          def initialize(invoice, today: Date.today)
            @invoice = invoice
            @today = today
          end

          def fee
            return 0 if days_late <= GRACE_DAYS

            raw = @invoice.amount * DAILY_RATE * (days_late - GRACE_DAYS)
            [raw, @invoice.amount * MAX_FEE_RATIO].min.round(2)
          end

          private

          def days_late
            (@today - @invoice.due_on).to_i
          end
        end
        """
      },
      %{
        id: "bl-code-18",
        mode: :code,
        genre: nil,
        text: ~S"""
        package org.example.library;

        import java.time.LocalDate;
        import java.util.ArrayList;
        import java.util.List;
        import java.util.Optional;

        public final class Shelf {
            private final List<Loan> loans = new ArrayList<>();

            public Loan checkOut(Book book, Member member, LocalDate today) {
                if (findActiveLoan(book).isPresent()) {
                    throw new IllegalStateException("Book already checked out: " + book.isbn());
                }
                Loan loan = new Loan(book, member, today, today.plusWeeks(3));
                loans.add(loan);
                return loan;
            }

            public Optional<Loan> findActiveLoan(Book book) {
                return loans.stream()
                        .filter(l -> l.book().equals(book) && l.returnedOn() == null)
                        .findFirst();
            }

            public List<Loan> overdue(LocalDate today) {
                return loans.stream()
                        .filter(l -> l.returnedOn() == null && l.dueOn().isBefore(today))
                        .toList();
            }
        }
        """
      },
      %{
        id: "bl-code-19",
        mode: :code,
        genre: nil,
        text: ~S"""
        .PHONY: build test lint clean

        BIN := bin/tracker
        SRC := $(shell find . -name '*.go' -not -path './vendor/*')

        build: $(BIN)

        $(BIN): $(SRC)
        	mkdir -p bin
        	go build -o $(BIN) ./cmd/tracker

        test:
        	go test ./... -count=1

        lint:
        	go vet ./...

        clean:
        	rm -rf bin
        """
      },
      %{
        id: "bl-code-20",
        mode: :code,
        genre: nil,
        text: ~S"""
        local Inventory = {}
        Inventory.__index = Inventory

        function Inventory.new(capacity)
          return setmetatable({ items = {}, capacity = capacity or 20 }, Inventory)
        end

        function Inventory:add(name, count)
          count = count or 1
          local current = self.items[name] or 0
          if self:total() + count > self.capacity then
            return false, "inventory full"
          end
          self.items[name] = current + count
          return true
        end

        function Inventory:total()
          local sum = 0
          for _, n in pairs(self.items) do
            sum = sum + n
          end
          return sum
        end

        return Inventory
        """
      },
      %{
        id: "bl-code-21",
        mode: :code,
        genre: nil,
        text: ~S"""
        data class Reading(val sensorId: String, val celsius: Double, val takenAt: Long)

        fun List<Reading>.averageBySensor(): Map<String, Double> =
            groupBy { it.sensorId }
                .mapValues { (_, readings) -> readings.map { it.celsius }.average() }

        fun main() {
            val readings = listOf(
                Reading("greenhouse-1", 21.4, 1_700_000_000),
                Reading("greenhouse-1", 22.0, 1_700_000_600),
                Reading("shed", 9.8, 1_700_000_000),
            )
            readings.averageBySensor().forEach { (id, avg) ->
                println("$id: ${"%.1f".format(avg)} C")
            }
        }
        """
      },
      %{
        id: "bl-code-22",
        mode: :code,
        genre: nil,
        text: ~S"""
        <?php

        declare(strict_types=1);

        function slugify(string $title, int $maxLength = 60): string
        {
            $slug = strtolower(trim($title));
            $slug = preg_replace('/[^a-z0-9]+/', '-', $slug) ?? '';
            $slug = trim($slug, '-');

            if (strlen($slug) > $maxLength) {
                $slug = rtrim(substr($slug, 0, $maxLength), '-');
            }

            return $slug === '' ? 'untitled' : $slug;
        }

        echo slugify("Ten Things We Learned Moving House"), PHP_EOL;
        """
      },
      %{
        id: "bl-code-23",
        mode: :code,
        genre: nil,
        text: ~S"""
        defmodule Billing.ProrationTest do
          use ExUnit.Case, async: true

          alias Billing.Proration

          describe "credit/3" do
            test "returns the full amount when cancelled on the first day" do
              assert Proration.credit(3000, ~D[2026-04-01], ~D[2026-04-01]) == 3000
            end

            test "returns zero on the last day of the period" do
              assert Proration.credit(3000, ~D[2026-04-01], ~D[2026-04-30]) == 0
            end

            test "rounds down to the nearest cent" do
              assert Proration.credit(1000, ~D[2026-04-01], ~D[2026-04-11]) == 666
            end
          end
        end
        """
      },
      %{
        id: "bl-code-24",
        mode: :code,
        genre: nil,
        text: ~S"""
        #!/usr/bin/env python3
        import argparse
        import csv
        import sys


        def main() -> int:
            parser = argparse.ArgumentParser(description="Sum a numeric column in a CSV file.")
            parser.add_argument("path")
            parser.add_argument("--column", required=True)
            parser.add_argument("--skip-errors", action="store_true")
            args = parser.parse_args()

            total = 0.0
            with open(args.path, newline="") as fh:
                for line_no, row in enumerate(csv.DictReader(fh), start=2):
                    try:
                        total += float(row[args.column])
                    except (KeyError, ValueError) as exc:
                        if not args.skip_errors:
                            print(f"line {line_no}: {exc}", file=sys.stderr)
                            return 1
            print(f"{total:.2f}")
            return 0


        if __name__ == "__main__":
            sys.exit(main())
        """
      },
      %{
        id: "bl-code-25",
        mode: :code,
        genre: nil,
        text: "find . -name '*.log' -mtime +7 -print0 | xargs -0 rm -f"
      },
      %{
        id: "bl-code-26",
        mode: :code,
        genre: nil,
        text: ~S"""
        public static class RetryPolicy
        {
            public static async Task<T> WithRetries<T>(
                Func<Task<T>> action,
                int maxAttempts = 3,
                TimeSpan? baseDelay = null)
            {
                var delay = baseDelay ?? TimeSpan.FromMilliseconds(200);
                for (var attempt = 1; ; attempt++)
                {
                    try
                    {
                        return await action();
                    }
                    catch (HttpRequestException) when (attempt < maxAttempts)
                    {
                        await Task.Delay(delay * Math.Pow(2, attempt - 1));
                    }
                }
            }
        }
        """
      },
      %{
        id: "bl-code-27",
        mode: :code,
        genre: nil,
        text: "UPDATE members SET active = false WHERE last_seen_at < now() - interval '1 year';"
      },

      # ------------------------------------------------------------------
      # Data
      # ------------------------------------------------------------------
      %{
        id: "bl-data-01",
        mode: :data,
        genre: nil,
        text: ~S"""
        {
          "order_id": "ORD-20391",
          "placed_at": "2026-04-11T08:42:10Z",
          "customer": { "id": 8812, "first_name": "Alma", "tier": "gold" },
          "items": [
            { "sku": "MUG-BLU-12", "qty": 2, "price": 14.5, "tags": ["ceramic", "gift"] },
            { "sku": "TEA-GRN-100", "qty": 1, "price": 9.0, "tags": [] }
          ],
          "shipping": {
            "method": "standard",
            "address": { "city": "Lisbon", "postcode": "1100-148", "country": "PT" },
            "tracking": [["2026-04-12", "label created"], ["2026-04-13", "in transit"]]
          },
          "total": 38.0
        }
        """
      },
      %{
        id: "bl-data-02",
        mode: :data,
        genre: nil,
        text: ~S"""
        {"ts":"2026-05-01T10:00:01Z","event":"page_view","user":"u_481","path":"/pricing"}
        {"ts":"2026-05-01T10:00:07Z","event":"click","user":"u_481","target":"start-trial"}
        {"ts":"2026-05-01T10:00:09Z","event":"signup","user":"u_481","plan":"team","referrer":null}
        {"ts":"2026-05-01T10:02:44Z","event":"page_view","user":"u_502","path":"/docs/getting-started"}
        {"ts":"2026-05-01T10:03:15Z","event":"search","user":"u_502","query":"export to csv","results":4}
        """
      },
      %{
        id: "bl-data-03",
        mode: :data,
        genre: nil,
        text: ~S"""
        date,store,category,units,revenue
        2026-03-01,North,coffee,412,1854.00
        2026-03-01,North,pastry,190,722.50
        2026-03-01,Harbor,coffee,288,1296.00
        2026-03-01,Harbor,pastry,95,361.00
        2026-03-02,North,coffee,397,1786.50
        2026-03-02,Harbor,coffee,301,1354.50
        """
      },
      %{
        id: "bl-data-04",
        mode: :data,
        genre: nil,
        text: ~S"""
        ticket_id,opened,customer,subject,body,status
        4410,2026-02-03,Rosa,"Can't log in","Hi, since this morning I get an error after entering my password.
        I already tried resetting it twice.
        Thanks",open
        4411,2026-02-03,Kenji,"Invoice question","Why is there a second line item called ""adjustment"" on my January invoice?",pending
        4412,2026-02-04,Amara,"Feature request: dark mode","Would love a dark theme, the app is very bright at night.",closed
        """
      },
      %{
        id: "bl-data-05",
        mode: :data,
        genre: nil,
        text: ~S"""
        id	name	department	start_date	remote
        101	Ada	Engineering	2024-09-02	yes
        102	Bruno	Sales	2025-01-13	no
        103	Chiara	Support	2025-03-17	yes
        104	Dev	Engineering	2025-06-30	yes
        """
      },
      %{
        id: "bl-data-06",
        mode: :data,
        genre: nil,
        text: ~S"""
        review_checklist:
          before_merging:
            - The change has been tested by someone other than the author.
            - Any new setting is documented in the admin guide.
            - The release note explains the change in plain language.
          before_releasing:
            - Support has seen the release note at least one day in advance.
            - Rollback steps are written down and someone has tried them.
        owners:
          checklist: Mira
          release_notes: Tobias
        """
      },
      %{
        id: "bl-data-07",
        mode: :data,
        genre: nil,
        text: ~S"""
        # Site generator settings
        title = "Field Notes"
        base_url = "https://notes.example.com"
        default_language = "en"

        [build]
        output_dir = "public"
        minify = true
        drafts = false

        [markdown]
        smart_punctuation = true
        highlight_theme = "light"

        [[menus.main]]
        name = "Archive"
        url = "/archive/"
        weight = 10

        [[menus.main]]
        name = "About"
        url = "/about/"
        weight = 20
        """
      },
      %{
        id: "bl-data-08",
        mode: :data,
        genre: nil,
        text: ~S"""
        ; Printer pool configuration for the second floor
        ; Edited by facilities, ask before changing the default

        [general]
        default = floor2-color
        retry_seconds = 30

        [floor2-color]
        address = 10.20.4.15
        duplex = true
        paper = A4

        [floor2-mono]
        address = 10.20.4.16
        duplex = true
        paper = A4
        ; mono printer jams on card stock, keep this off
        allow_heavy_paper = false
        """
      },
      %{
        id: "bl-data-09",
        mode: :data,
        genre: nil,
        text: ~S"""
        # local development only
        APP_ENV=development
        APP_PORT=4000
        DATABASE_HOST=localhost
        DATABASE_PORT=5432
        DATABASE_NAME=app_dev
        DATABASE_USER=app
        DATABASE_PASSWORD=changeme
        CACHE_TTL_SECONDS=300
        FEATURE_NEW_EDITOR=true
        MAIL_FROM=no-reply@example.com
        LOG_LEVEL=debug
        """
      },
      %{
        id: "bl-data-10",
        mode: :data,
        genre: nil,
        text: ~S"""
        | Week | Visitors | Sign-ups | Conversion |
        |------|----------|----------|------------|
        | 14   | 12,480   | 311      | 2.49%      |
        | 15   | 13,105   | 342      | 2.61%      |
        | 16   | 11,920   | 298      | 2.50%      |
        | 17   | 15,770   | 455      | 2.89%      |
        """
      },
      %{
        id: "bl-data-11",
        mode: :data,
        genre: nil,
        text: ~S"""
        <?xml version="1.0" encoding="UTF-8"?>
        <invoice number="INV-0912" issued="2026-07-01" currency="EUR">
          <seller>
            <name>Example Print Shop</name>
            <vat>XX123456789</vat>
          </seller>
          <buyer>
            <name>Example Bakery</name>
          </buyer>
          <lines>
            <line sku="FLY-A5" qty="500" unit="0.08"/>
            <line sku="POS-A2" qty="20" unit="2.40"/>
          </lines>
          <total>88.00</total>
        </invoice>
        """
      },
      %{
        id: "bl-data-12",
        mode: :data,
        genre: nil,
        text: ~S"""
        10.0.3.17 - - [12/Mar/2026:07:14:02 +0000] "GET /api/projects?page=2 HTTP/1.1" 200 5123 "-" "mobile-app/4.2"
        10.0.3.17 - - [12/Mar/2026:07:14:03 +0000] "GET /api/projects/88/tasks HTTP/1.1" 200 18044 "-" "mobile-app/4.2"
        10.0.7.2 - - [12/Mar/2026:07:14:05 +0000] "POST /api/login HTTP/1.1" 401 88 "-" "browser/1.0"
        10.0.7.2 - - [12/Mar/2026:07:14:09 +0000] "POST /api/login HTTP/1.1" 200 412 "-" "browser/1.0"
        10.0.1.40 - - [12/Mar/2026:07:14:11 +0000] "GET /health HTTP/1.1" 200 2 "-" "probe/1.0"
        """
      },
      %{
        id: "bl-data-13",
        mode: :data,
        genre: nil,
        text: ~S"""
        time=2026-09-03T14:22:01Z level=info msg="job started" job=invoice-reminders batch=17
        time=2026-09-03T14:22:04Z level=warn msg="retrying send" job=invoice-reminders attempt=2 recipient_id=5531
        time=2026-09-03T14:22:09Z level=info msg="job finished" job=invoice-reminders sent=412 skipped=3 duration_ms=8120
        time=2026-09-03T14:30:00Z level=error msg="lock not acquired" job=nightly-rollup holder=worker-2
        """
      },
      %{
        id: "bl-data-14",
        mode: :data,
        genre: nil,
        text: ~S"""
        [
          {"id": 1, "title": "Replace hallway bulbs", "assignee": "Omar", "due": "2026-05-04", "done": true},
          {"id": 2, "title": "Order printer toner", "assignee": "Lin", "due": "2026-05-06", "done": false},
          {"id": 3, "title": "Book fire safety check", "assignee": null, "due": "2026-05-15", "done": false}
        ]
        """
      },
      %{
        id: "bl-data-15",
        mode: :data,
        genre: nil,
        text: ~S"""
        # Worker settings. Values here override the defaults in the image.
        server:
          host: 0.0.0.0
          port: 8080
          read_timeout: 15s

        queue:
          name: thumbnails
          concurrency: 8        # raise carefully, each job uses ~200MB
          max_retries: 5
          dead_letter: thumbnails-failed

        storage:
          bucket: media-prod
          prefixes:
            originals: originals/
            thumbs: thumbs/
          sizes: [64, 256, 1024]
        """
      },
      %{
        id: "bl-data-16",
        mode: :data,
        genre: nil,
        text: ~S"""
        Artikel;Menge;Preis;Lager
        Schrauben M4;1200;0,04;A-12
        Dübel 6mm;800;0,07;A-12
        Winkel 40x40;150;0,85;B-03
        Kabelbinder 200mm;2500;0,02;C-01
        """
      },
      %{
        id: "bl-data-17",
        mode: :data,
        genre: nil,
        text: ~S"""
        ACCT|NAME|OPENED|BALANCE|STATUS
        000417|Mila|2019-04-22|1520.75|ACTIVE
        000418|Arjun|2020-11-03|0.00|CLOSED
        000419|Teresa|2021-02-14|88.10|ACTIVE
        000420|Yaw|2023-08-30|-12.40|OVERDRAWN
        """
      },
      %{
        id: "bl-data-18",
        mode: :data,
        genre: nil,
        text: ~S"""
        {
          // Editor settings shared by the whole team.
          "tabSize": 2,
          "insertFinalNewline": true,
          "trimTrailingWhitespace": true,
          /* Spell checker: add product words here instead of ignoring the warning. */
          "spelling.words": ["onboarding", "upsell", "workspace"],
          "files.exclude": {
            "**/build": true,
            "**/.cache": true
          }
        }
        """
      },
      %{
        id: "bl-data-19",
        mode: :data,
        genre: nil,
        text: ~S"""
        Oct  3 02:15:01 web-04 CRON[18823]: (root) CMD (/usr/local/bin/rotate-exports)
        Oct  3 02:15:02 web-04 rotate-exports[18824]: removed 37 files older than 1 day
        Oct  3 02:17:44 web-04 kernel: [881203.44] eth0: link down
        Oct  3 02:17:47 web-04 kernel: [881206.91] eth0: link up, 1000 Mbps, full duplex
        Oct  3 02:18:00 web-04 healthd[902]: status=degraded reason=link_flap
        """
      },
      %{
        id: "bl-data-20",
        mode: :data,
        genre: nil,
        text: ~S"""
        {
          "type": "FeatureCollection",
          "features": [
            {
              "type": "Feature",
              "properties": { "name": "Community garden", "plots": 24 },
              "geometry": { "type": "Point", "coordinates": [-9.1427, 38.7369] }
            },
            {
              "type": "Feature",
              "properties": { "name": "Bike path, east section" },
              "geometry": {
                "type": "LineString",
                "coordinates": [[-9.140, 38.735], [-9.136, 38.737], [-9.131, 38.738]]
              }
            }
          ]
        }
        """
      },
      %{
        id: "bl-data-21",
        mode: :data,
        genre: nil,
        text: ~S"""
        sku,qty
        A-100,4
        B-220,0
        """
      },
      %{
        id: "bl-data-22",
        mode: :data,
        genre: nil,
        text: ~S"""
        - name: Ines
          role: Coordinator
          shifts: [mon, wed, fri]
          languages: [pt, en]
        - name: Bo
          role: Driver
          shifts: [tue, thu]
          languages: [en]
        - name: Farah
          role: Kitchen
          shifts: [mon, tue, sat]
          languages: [en, ar, fr]
        """
      },
      %{
        id: "bl-data-23",
        mode: :data,
        genre: nil,
        text: ~S"""
        stages: [test, build, deploy]

        variables:
          APP_ENV: test

        test:
          stage: test
          script:
            - make deps
            - make test
          artifacts:
            paths: [coverage/]

        build:
          stage: build
          script:
            - make release
          only: [main]

        deploy:
          stage: deploy
          script:
            - ./ops/deploy --env staging
          when: manual
        """
      },
      %{
        id: "bl-data-24",
        mode: :data,
        genre: nil,
        text: ~S"""
        {"status":"ok","data":{"user":{"id":42,"roles":["editor","billing"]},"flags":{"beta":true}},"took_ms":12}
        """
      },
      %{
        id: "bl-data-25",
        mode: :data,
        genre: nil,
        text: ~S"""
        # Messages for the checkout screen (English)
        checkout.title=Review your order
        checkout.button.pay=Pay now
        checkout.error.card_declined=Your card was declined. Please try another one.
        checkout.error.generic=Something went wrong. You have not been charged.
        checkout.summary.items={0} items
        checkout.summary.shipping=Shipping: {0}
        """
      },
      %{
        id: "bl-data-26",
        mode: :data,
        genre: nil,
        text: ~S"""
        | Region | Q1  | Q2  | Q3  | Change |
        |:-------|----:|----:|----:|-------:|
        | North  | 118 | 124 | 131 | +5.6%  |
        | South  | 96  | 91  | 99  | +8.8%  |
        | West   | 143 | 150 | 147 | -2.0%  |
        """
      },
      %{
        id: "bl-data-27",
        mode: :data,
        genre: nil,
        text: ~S"""
        2026-06-18 09:41:12.004 INFO  [main] Starting scheduler with 4 workers
        2026-06-18 09:41:12.310 INFO  [worker-1] Picked up job 8812 (send-digest)
        2026-06-18 09:41:13.902 WARN  [worker-1] Template "digest-v2" missing locale "nl", falling back to "en"
        2026-06-18 09:41:15.117 ERROR [worker-3] Job 8815 failed: timeout after 30000 ms
        2026-06-18 09:41:15.118 INFO  [worker-3] Job 8815 rescheduled in 120 s (attempt 2 of 5)
        """
      },

      # ------------------------------------------------------------------
      # Visual
      # ------------------------------------------------------------------
      %{
        id: "bl-visual-01",
        mode: :visual,
        genre: nil,
        text: ~S"""
        ```mermaid
        flowchart TD
            A[Order placed] --> B{Paid?}
            B -- yes --> C[Reserve stock]
            B -- no --> D[Send payment reminder]
            D --> B
            C --> E{In stock?}
            E -- yes --> F[Ship]
            E -- no --> G[Notify customer of delay]
            G --> F
        ```
        """
      },
      %{
        id: "bl-visual-02",
        mode: :visual,
        genre: nil,
        text: ~S"""
        sequenceDiagram
            participant U as User
            participant W as Web app
            participant A as Auth service
            U->>W: Submit login form
            W->>A: Verify credentials
            A-->>W: Token
            W-->>U: Redirect to dashboard
            Note over W,A: Token expires after 1 hour
        """
      },
      %{
        id: "bl-visual-03",
        mode: :visual,
        genre: nil,
        text: ~S"""
        digraph deploy {
            rankdir=LR;
            node [shape=box, style=rounded];

            commit -> build -> test;
            test -> staging [label="pass"];
            test -> notify [label="fail", color=red];
            staging -> approval -> production;
        }
        """
      },
      %{
        id: "bl-visual-04",
        mode: :visual,
        genre: nil,
        text: ~S"""
        @startuml
        actor Customer
        rectangle "Library" {
          usecase "Search catalogue" as UC1
          usecase "Borrow book" as UC2
          usecase "Renew loan" as UC3
        }
        actor Librarian
        Customer --> UC1
        Customer --> UC2
        Customer --> UC3
        Librarian --> UC2
        UC3 .> UC2 : <<extends>>
        @enduml
        """
      },
      %{
        id: "bl-visual-05",
        mode: :visual,
        genre: nil,
        text: ~S"""
        <svg xmlns="http://www.w3.org/2000/svg" width="240" height="120" viewBox="0 0 240 120">
          <rect x="0" y="0" width="240" height="120" fill="#f5f2ea"/>
          <g fill="#3b6ea5">
            <rect x="20" y="70" width="30" height="40"/>
            <rect x="65" y="50" width="30" height="60"/>
            <rect x="110" y="30" width="30" height="80"/>
            <rect x="155" y="45" width="30" height="65"/>
          </g>
          <line x1="10" y1="110" x2="230" y2="110" stroke="#333" stroke-width="1"/>
          <text x="20" y="20" font-family="sans-serif" font-size="12" fill="#333">Weekly orders</text>
        </svg>
        """
      },
      %{
        id: "bl-visual-06",
        mode: :visual,
        genre: nil,
        text: ~S"""
        ## Site visit, 4 June

        ![North facade before cleaning](photos/site-0604-north-facade.jpg)
        ![Water damage under the east window](photos/site-0604-east-window.jpg)
        ![Roof access hatch, hinge broken](photos/site-0604-roof-hatch.jpg)
        ![Basement, standing water near the boiler](photos/site-0604-basement.jpg)
        """
      },
      %{
        id: "bl-visual-07",
        mode: :visual,
        genre: nil,
        text: ~S"""
        gantt
            title Kitchen renovation
            dateFormat  YYYY-MM-DD
            section Prep
            Remove old cabinets   :done,    a1, 2026-05-04, 3d
            Electrical rough-in   :active,  a2, after a1, 4d
            section Build
            Install cabinets      :         b1, after a2, 5d
            Countertops           :         b2, after b1, 2d
            section Finish
            Paint and trim        :         c1, after b2, 3d
        """
      },
      %{
        id: "bl-visual-08",
        mode: :visual,
        genre: nil,
        text: ~S"""
        stateDiagram-v2
            [*] --> Draft
            Draft --> InReview: submit
            InReview --> Draft: request changes
            InReview --> Approved: approve
            Approved --> Published: publish
            Published --> Archived: archive
            Archived --> [*]
        """
      }
    ]
  end
end
