defmodule OptimalEngine.SignalEvalHoldout do
  @moduledoc """
  Held-out, independently labeled evaluation samples for the signal classifier.

  Every sample is a map with the keys `:id`, `:text`, `:mode` and `:genre`.
  The labels were assigned by reading each text as a careful human would,
  without looking at the classifier implementation, so that the set can
  expose weaknesses instead of confirming them.

  All content is generic and fictional.
  """

  @type sample :: %{
          id: String.t(),
          text: String.t(),
          mode: :linguistic | :code | :data | :visual | :mixed,
          genre: String.t() | nil
        }

  @spec samples() :: [sample()]
  def samples do
    transcripts() ++
      emails() ++
      messages() ++
      notes() ++
      specs() ++
      decision_logs() ++
      standups() ++
      postmortems() ++
      runbooks() ++
      plans() ++
      briefs() ++
      changelogs() ++
      acknowledgements() ++
      code() ++
      data() ++
      mixed() ++
      visual()
  end

  # ---------------------------------------------------------------------------
  # transcripts
  # ---------------------------------------------------------------------------

  defp transcripts do
    [
      %{
        id: "ho-transcript-01",
        text: ~S"""
        [00:00:03] Alice: Okay, I think we're recording. Can everyone hear me?
        [00:00:06] Bob: Yep, loud and clear.
        [00:00:08] Priya: Same here.
        [00:00:12] Alice: Great. So the agenda today is the pricing page, the onboarding emails, and whether we push the launch to the 14th.
        [00:00:25] Bob: I'd start with the launch date, because everything else depends on it.
        [00:00:31] Alice: Fair. Priya, where are we on QA?
        [00:00:36] Priya: About two thirds done. The checkout flow is solid, but the invite flow still drops the team name on some browsers.
        [00:00:49] Bob: Is that a blocker?
        [00:00:51] Priya: For a public launch, yes. For the beta cohort, no.
        [00:01:02] Alice: Then we keep the 7th for the beta and move the public date to the 14th. Any objections?
        [00:01:10] Bob: None from me.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-02",
        text: ~S"""
        Speaker 1: Thanks for jumping on with me, I know it's early.
        Speaker 2: No problem at all. I wanted to talk about the renewal anyway.
        Speaker 1: Right, so the contract ends in November, and we'd like to move to the annual plan.
        Speaker 2: Okay. What's driving that?
        Speaker 1: Mostly budget predictability. Finance wants one number for the year instead of twelve small ones.
        Speaker 2: That makes sense. Let me check what discount we can offer on annual and get back to you by Thursday.
        Speaker 1: Perfect.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-03",
        text: ~S"""
        Tomas  00:04
        So the thing I keep running into is that the export takes forever when there are more than ten thousand rows.

        Maya  00:14
        Is it the query or is it the formatting step?

        Tomas  00:19
        I think it's the formatting. The query comes back in under a second when I run it by hand.

        Maya  00:27
        Then let's profile the formatter first before we touch the database.

        Tomas  00:33
        Okay. I can do that this afternoon and post what I find in the channel.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-04",
        text: ~S"""
        so um yeah i think the main thing is like we need to figure out who owns the onboarding flow because right now its kind of nobody and uh everybody at the same time you know and then when something breaks we all just sort of look at each other so i would say lets pick one person and make them the dri for like a month and see how it goes and um if it works we keep it okay yeah that makes sense i can take it for the first month honestly i was gonna ask anyway
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-05",
        text: ~S"""
        ALICE: Okay, so who's taking the vendor call?
        BOB: I can do it, but I have a hard stop at four.
        PRIYA: [crosstalk] I thought that was moved to Friday.
        ALICE: Wait, say that again, you both cut out.
        PRIYA: The vendor call. It moved to Friday. They emailed yesterday.
        BOB: [laughs] Of course it did.
        ALICE: [pause] Fine. Friday then. Bob, you're still on it?
        BOB: Yes, Friday works better anyway.
        [inaudible]
        ALICE: Sorry, what was that last bit?
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-06",
        text: ~S"""
        Priya (00:00:05): Welcome back, everyone. Today I'd like to walk through the Q3 support numbers.
        Tomas (00:00:14): Before you start, can we get the slide deck link in the chat?
        Priya (00:00:18): Sure, sending it now.
        Priya (00:00:41): So, first response time dropped from nineteen hours to six. That's the headline.
        Alice (00:00:52): What changed? Did we hire?
        Priya (00:00:57): Two things. We hired one person, and we started routing billing questions straight to a dedicated queue instead of the general inbox.
        Alice (00:01:03): Nice. Does that hold up on weekends?
        Priya (00:01:08): Not yet. Weekends are still a gap.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-07",
        text: ~S"""
        1
        00:00:01,000 --> 00:00:04,200
        Welcome to the weekly planning call.

        2
        00:00:04,500 --> 00:00:08,900
        Today we're going to cover three things: hiring, the roadmap, and the offsite.

        3
        00:00:09,300 --> 00:00:13,100
        Let's start with hiring, since that affects the other two.

        4
        00:00:13,600 --> 00:00:18,000
        We have two open roles and only one of them has a real pipeline.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-08",
        text: ~S"""
        Q: How did you first get into woodworking?
        A: My grandfather had a small shop behind the house. I spent most summers there sanding things that didn't need sanding.
        Q: And when did it become a business?
        A: Around 2019. A neighbor asked me to build a table, then her friend asked for two chairs, and it kind of snowballed.
        Q: What's the hardest part of running it?
        A: Honestly, saying no. I used to take every order, and now I'm learning to turn down the ones that don't fit.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-09",
        text: ~S"""
        Weekly sync - Tuesday
        Attendees: Alice, Bob, Priya

        Alice: Let's go through last week's actions. Bob, did you get the vendor quote?
        Bob: Got it yesterday. It came in about ten percent over our budget.
        Alice: Can we negotiate?
        Bob: I think so. They said the number is flexible if we sign for two years.
        Priya: I'd be careful with two years. Our needs could change after the reorg.
        Alice: Agreed. Bob, ask for the one-year price with a renewal cap instead.
        Bob: Will do. I'll email them today.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-10",
        text: ~S"""
        Alice: Did you get my message about the invoice?
        Bob: Yeah, I'll send it over after lunch.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-11",
        text: ~S"""
        >> Thanks everyone for coming. We have a packed agenda, so let's get started.
        >> First item is the budget. Dana, can you take us through it?
        >> Sure. We came in about four percent under for the quarter, mostly because two hires slipped into next quarter.
        >> So that's not really savings, it's timing.
        >> Exactly. It'll come back in Q2.
        >> Okay. Any questions before we move on? [silence] Great.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-12",
        text: ~S"""
        [10:02] Alice: So the customer wants us to import the contacts from their old system before the go-live.
        [10:05] Bob: How many are we talking about?
        [10:06] Alice: Roughly forty thousand, with a lot of duplicates.
        [10:09] Priya: We require a clean-up pass first. I don't want to import the mess and fix it later.
        [10:14] Bob: I agree. And honestly the duplicate problem deserves a first class fix, not another one-off script.
        [10:19] Alice: Okay. Let's make that the function of the next sprint then: dedupe first, import second.
        [10:23] Bob: Works for me.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-13",
        text: ~S"""
        HOST: Welcome back to the show. Today we're talking about how small teams handle on-call without burning out.
        GUEST: Thanks for having me. I think the first thing to say is that on-call is a design problem, not a heroics problem.
        HOST: Say more about that.
        GUEST: If the same person gets paged at three in the morning every week, the system is telling you something. Either the alerts are too noisy or the service is too fragile. Rotating faster doesn't fix either of those, it just spreads the pain.
        HOST: So what does fix it?
        GUEST: Fewer, better alerts. And a rule that every page produces either a fix or a deleted alert within a week.
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-14",
        text: ~S"""
        Alice: Let's start with the roadmap. (00:12)
        Bob: I have three items I want to flag. (00:17)
        Alice: Go ahead. (00:19)
        Bob: One, the mobile release slipped a week. Two, the partner integration is waiting on their side. Three, we still don't have a designer for the summer. (00:38)
        Priya: On the third one, I know someone who might be free in July. I can make an intro. (00:46)
        Alice: That would help a lot. (00:49)
        """,
        mode: :linguistic,
        genre: "transcript"
      },
      %{
        id: "ho-transcript-15",
        text: ~S"""
        [Call started 14:32]

        Agent: Thanks for calling, this is Dana, how can I help?
        Caller: Hi, yes, I got a charge on my card that I don't recognize.
        Agent: I'm sorry about that. Which card did you use for the account?
        Caller: It's the one I use for work.
        Agent: Thanks. [typing] I see a charge from the nineteenth for twelve dollars. Does that sound familiar?
        Caller: No, I cancelled that subscription in August.
        Agent: Let me look at the account history. One moment please.
        [hold music, 40 seconds]
        Agent: Okay, I see the problem. The cancellation didn't go through. I'll refund the charge now.
        Caller: Oh, thank you so much.
        [Call ended 14:41]
        """,
        mode: :linguistic,
        genre: "transcript"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # emails
  # ---------------------------------------------------------------------------

  defp emails do
    [
      %{
        id: "ho-email-01",
        text: ~S"""
        From: Priya <priya@example.com>
        To: Alice <alice@example.com>
        Cc: Bob <bob@example.com>
        Subject: Updated timeline for the migration
        Date: Tue, 3 Mar 2026 09:14:22 +0000

        Hi Alice,

        Quick update on the migration. We finished the staging dry run yesterday and found two issues, both minor:

        1. Some legacy accounts have no timezone set, so their reports show UTC.
        2. The nightly job takes about 40 minutes longer than estimated.

        Neither one blocks the cutover, so I'm still planning for Saturday the 14th. I'll send a go/no-go note on Thursday.

        Let me know if you want to talk it through.

        Best,
        Priya
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-02",
        text: ~S"""
        Subject: Re: Venue for the offsite

        Sounds good to me, let's go with the lakeside place. I'll check with Tomas about the budget.

        Thanks,
        Bob

        On Mon, Feb 9, 2026 at 4:02 PM Alice <alice@example.com> wrote:
        > Hi all,
        >
        > I got quotes from two venues. The lakeside place is $4,200 for two nights
        > and includes breakfast. The downtown option is cheaper at $3,100 but has
        > no meeting room.
        >
        > I lean toward the lakeside place. Thoughts?
        >
        > Alice
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-03",
        text: ~S"""
        Alice, see below. Can you confirm whether the replacement is the new model?
        -- Tomas

        ---------- Forwarded message ---------
        From: Support Desk <support@example.com>
        Date: Wed, Apr 8, 2026 at 11:30 AM
        Subject: Your ticket #2291 has been updated
        To: Tomas <tomas@example.com>

        Hello Tomas,

        Your ticket has been updated by our team. We replaced the faulty unit and it shipped this morning. Tracking details will follow in a separate email.

        Regards,
        Support Team
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-04",
        text: ~S"""
        hey tomas,

        just saw your note. yeah i can do thursday afternoon, anytime after 2 works. should i bring the samples or are you good? also dont forget we need to talk about the shipping thing, the carrier raised rates again.

        talk soon
        m
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-05",
        text: ~S"""
        Subject: Invoice 1042 - payment reminder

        Dear Priya,

        This is a friendly reminder that invoice 1042 for $1,850.00 was due on March 1. If you have already sent payment, please disregard this message.

        You can pay by bank transfer using the details on the invoice. Please let me know if you need a copy re-sent.

        Kind regards,

        Dana
        Accounts Receivable
        Example Studio, Ltd.
        T: 555-0100 | www.example.com

        This email and any attachments are confidential and intended solely for the addressee. If you have received it in error, please notify the sender and delete it.
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-06",
        text: ~S"""
        Subject: Can we move Thursday's call?

        Hi Bob,

        Something came up on my side and I won't be able to make Thursday at 10. Would Friday at the same time work for you? If not, I'm free any time on Monday.

        Sorry for the shuffle.

        Alice
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-07",
        text: ~S"""
        Subject: Re: Can't log in after password reset

        Hi Sam,

        Thanks for getting in touch, and sorry for the trouble. It looks like the reset link you used had already expired (they're valid for 30 minutes). I've sent you a fresh one just now, so please check your inbox and spam folder.

        If it still doesn't work after that, reply here and I'll set up a call so we can sort it out together.

        Cheers,
        Marta
        Customer Care
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-08",
        text: ~S"""
        Subject: Re: lunch?

        Can't today, swamped. Tomorrow?

        - P
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-09",
        text: ~S"""
        Hi team,

        Please see Alice's note below and reply with your availability by end of day.

        Thanks,
        Tomas

        ________________________________
        From: Alice <alice@example.com>
        Sent: Monday, March 16, 2026 8:41 AM
        To: Tomas <tomas@example.com>
        Subject: Workshop dates

        Tomas,

        We're considering April 7-8 or April 21-22 for the workshop. Which is better for your group?

        Alice
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-10",
        text: ~S"""
        Subject: Import problems on the contacts page

        Hi Bob,

        Customers keep telling us that the import on the contacts page fails when the file has more than one header row. I know we said the function of that screen was just to take clean files, but in practice nobody sends clean files. I think we need a first class fix here, and I'd like to require a preview step before the import runs.

        Can you take a look this week and tell me what you think the effort is?

        Thanks,
        Alice
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-11",
        text: ~S"""
        Subject: Automatic reply: Out of office

        Hello,

        I'm out of the office until Monday, April 6, with limited access to email. For anything urgent, please contact Bob at bob@example.com. Otherwise I'll reply as soon as I'm back.

        Best regards,
        Priya
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-12",
        text: ~S"""
        Subject: Weekly update - week of June 8

        Hi everyone,

        Highlights from this week:

        - The new onboarding checklist went live on Tuesday. Early signups completing setup are up 12%.
        - We closed three support tickets that had been open for over a month.
        - Hiring: two final interviews scheduled for next week.

        Heads up for next week: the office will be closed on Friday for the holiday.

        Have a good weekend,
        Alice
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-13",
        text: ~S"""
        Hi Tomas,

        Thanks again for the intro to Maya, we had a great first call. She's going to send over a rough scope by Friday and then we'll decide whether to move forward.

        I owe you a coffee.

        Best,
        Bob
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-14",
        text: ~S"""
        Subject: Quick question about your packaging

        Hello,

        I came across your shop while looking for refillable soap containers. Do you offer wholesale pricing for orders over 500 units? We run a small chain of five stores and are looking for a new supplier before the holiday season.

        If it's easier to talk, I'm free most afternoons.

        Thank you,
        Ines
        Purchasing, Corner Market Group
        ines@example.com
        """,
        mode: :linguistic,
        genre: "email"
      },
      %{
        id: "ho-email-15",
        text: ~S"""
        > can you send the final deck before the call?

        yep, attached. one thing, slide 7 still has the old numbers, ill fix it tonight and resend

        > also is the customer joining?

        not sure, i asked them yesterday and havent heard back
        """,
        mode: :linguistic,
        genre: "email"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # chat messages
  # ---------------------------------------------------------------------------

  defp messages do
    [
      %{
        id: "ho-message-01",
        text:
          "@priya can you take a look at the PR when you get a sec? it's the one for the login redirect bug https://example.com/pr/482 🙏",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-02",
        text: "lol yeah that build has been flaky all week, i'll rerun it",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-03",
        text: "hey! are we still on for 3pm today or should I push it to tomorrow?",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-04",
        text: "try `npm ci` instead of `npm install`, the lockfile was out of sync",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-05",
        text: ~S"""
        morning all ☀️
        heads up, the staging server will be down from 2-3pm for the upgrade. please don't deploy anything during that window
        thx!
        """,
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-06",
        text: "@bob did you see my message abt the invoice? no rush but client keeps asking",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-07",
        text: "sorry im runnin late, stuck on the train, be there in like 15",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-08",
        text:
          "btw the config is in `config/app.yml`, the key you want is `retry_limit`. default is 3 which is too low imo",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-09",
        text: "Congrats on the launch!!! 🎉🎉 you all deserve it",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-10",
        text:
          "@here quick poll: standup at 9:30 or 10 tomorrow? react with 🕘 for 9:30 and 🕙 for 10",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-11",
        text:
          "hey can you import the contacts from that csv before the demo? i also need a function that returns the top 5 by revenue, no rush",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-12",
        text:
          "found a good article on this https://example.com/blog/retry-backoff, might help with the flaky uploads",
        mode: :linguistic,
        genre: "message"
      },
      %{id: "ho-message-13", text: ":eyes: looking now", mode: :linguistic, genre: "message"},
      %{
        id: "ho-message-14",
        text:
          "@Maya the :bug: is reproducible on mobile only, desktop is fine. screenshots in the thread",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-15",
        text:
          "Hi Priya, just checking in on the proposal. Did you get a chance to look at it? Happy to jump on a quick call if it's easier. Thanks!",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-16",
        text: "gm! coffee run anyone? I'm buying today ☕",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-17",
        text: "can u send me the wifi password for the new office?? mine isnt working",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-18",
        text:
          "+1 to this. we hit the same thing last month and the fix was just bumping the timeout, `client.timeout = 30` in our case",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-19",
        text: "Running 10 min late, start without me",
        mode: :linguistic,
        genre: "message"
      },
      %{
        id: "ho-message-20",
        text:
          "@alice @bob @priya reminder: retro is at 4 in room B, bring one thing that went well and one that didn't",
        mode: :linguistic,
        genre: "message"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # notes
  # ---------------------------------------------------------------------------

  defp notes do
    [
      %{
        id: "ho-note-01",
        text: "idea: let users pin a workspace so the sidebar remembers it between sessions",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-02",
        text:
          "Observation: the import step takes ~4x longer on Mondays. weekend backlog? check queue depth before blaming the parser.",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-03",
        text: ~S"""
        TODO before Friday
        - [ ] renew the domain
        - [ ] call Tomas about the quote
        - [x] send invoice to Dana
        - [ ] book flights for the offsite
        """,
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-04",
        text: "reminder: return the library books by friday (they're in the blue bag by the door)",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-05",
        text: "signup -> verify email -> onboarding => first project created (target: under 5 min)",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-06",
        text: ~S"""
        Pricing thoughts
        - class-based tiers might be too complex, people just want small / medium / big
        - need to require annual commitment for the top tier?
        - let customers return unused seats within 30 days
        - first class support for nonprofits (free? discounted?)
        """,
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-07",
        text:
          "const vs let debate in code review again. decision for now: default to const, use let only when the value is reassigned. stop arguing about it.",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-08",
        text: ~S"""
        Prep for call with Maya
        - she cares about turnaround time more than price
        - ask about the delays in March
        - bring sample pack
        - don't mention the other supplier yet
        """,
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-09",
        text:
          "Thought: the onboarding emails are doing the work the product should do. If people need email #3 to find the import button, the button is in the wrong place.",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-10",
        text:
          "Book recs from Priya: something on negotiation, something on systems thinking, and a novel for the flight.",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-11",
        text: ~S"""
        - bug: date picker shows yesterday when the timezone is behind UTC
        - repro: set tz to Pacific, pick the 1st
        - suspect: we parse as UTC then format as local
        """,
        mode: :linguistic,
        genre: "note"
      },
      %{id: "ho-note-12", text: "call dentist mon am", mode: :linguistic, genre: "note"},
      %{
        id: "ho-note-13",
        text:
          "Learned today: if a function returns early on error, the cleanup has to live in a finally block or you leak the handle. Wrote it on the whiteboard so the next person sees it.",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-14",
        text: ~S"""
        Flow sketch:
        request => queue => worker -> store
        retry on fail (max 3), then dead-letter => alert
        """,
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-15",
        text: ~S"""
        Ideas for the newsletter
        1. a "what we shipped" section, 3 bullets max
        2. customer spotlight, ask Marta who's willing
        3. one honest mistake per issue
        4. link roundup (keep it to five)
        """,
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-16",
        text:
          "Note: Alice prefers mornings for calls, Bob prefers chat over email, Priya wants an agenda sent the day before.",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-17",
        text: ~S"""
        # groceries
        - oat milk
        - limes
        - batteries (AA)
        - something for dinner Friday
        """,
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-18",
        text:
          "Decision pending: should the import module require login up front? Leaning yes. Come back to it after the demo.",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-19",
        text:
          "Standing desk: raised it 2cm, wrist pain gone after three days. Keep a log for two weeks before telling Bob it works.",
        mode: :linguistic,
        genre: "note"
      },
      %{
        id: "ho-note-20",
        text: ~S"""
        what went wrong with the Q2 launch (for retro)
        - we announced before the docs were ready
        - the pricing page said one thing, the invoice said another
        - nobody owned the rollback plan
        - good: the demo video landed really well
        """,
        mode: :linguistic,
        genre: "note"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # specs
  # ---------------------------------------------------------------------------

  defp specs do
    [
      %{
        id: "ho-spec-01",
        text: ~S"""
        # CSV Export - Specification

        ## Goal
        Allow users to export any table view as a CSV file.

        ## Requirements
        1. The export button MUST appear in the toolbar of every table view.
        2. The exported file MUST contain only the columns currently visible.
        3. Rows MUST respect the active filters and sort order.
        4. Exports with more than 50,000 rows SHOULD run in the background and notify the user by email when ready.
        5. The file name MUST follow the pattern view-name-date.csv.

        ## Non-goals
        - Excel or PDF export.
        - Scheduled exports.

        ## Acceptance
        - A user can export a filtered view of 10 rows and open it in a spreadsheet without errors.
        - A 100,000 row export does not block the UI.
        """,
        mode: :linguistic,
        genre: "spec"
      },
      %{
        id: "ho-spec-02",
        text: ~S"""
        Password Reset Flow - Spec v2

        Overview
        Users who forget their password must be able to regain access without contacting support.

        Functional requirements
        1. The login page shows a "Forgot password?" link.
        2. Submitting an email address always shows the same confirmation message, whether or not the account exists.
        3. If the account exists, an email with a single-use reset link is sent.
        4. The link expires after 30 minutes.
        5. After a successful reset, all existing sessions for that account are ended.

        Constraints
        - No more than 5 reset emails per account per hour.
        - The reset page must work without JavaScript.

        Open questions
        - Should we notify the user by email when the password has changed? (Leaning yes.)
        """,
        mode: :linguistic,
        genre: "spec"
      },
      %{
        id: "ho-spec-03",
        text: ~S"""
        Notification Preferences - Requirements

        R1. Each user can choose, per notification type, between email, in-app, both, or none.
        R2. Security notifications (password change, new device login) cannot be turned off.
        R3. Changes take effect immediately and apply to notifications created after the change.
        R4. The default for new accounts is both for mentions and none for marketing.
        R5. Preferences are exposed on a single settings page grouped by category.

        Out of scope: per-project overrides, quiet hours.
        """,
        mode: :linguistic,
        genre: "spec"
      },
      %{
        id: "ho-spec-04",
        text: ~S"""
        API Rate Limiting - Specification

        Goal: protect the service from accidental and abusive overload while keeping normal clients unaffected.

        1. Limits are applied per API key.
        2. The default limit is 600 requests per minute, with a burst allowance of 100.
        3. When a client exceeds the limit the service responds with status 429 and a Retry-After header giving the number of seconds to wait.
        4. Every response includes headers showing the limit, the remaining quota and the reset time.
        5. Limits for individual customers can be raised by support without a deploy.

        Acceptance: a load test at 2x the limit must see 429 responses within one second and no increase in latency for other keys.
        """,
        mode: :linguistic,
        genre: "spec"
      },
      %{
        id: "ho-spec-05",
        text: ~S"""
        Search - User stories and requirements

        As a user, I want to find a document by typing part of its title, so that I do not have to browse folders.
        As a user, I want recent searches suggested, so that I can repeat common queries quickly.
        As an admin, I want search to respect permissions, so that people never see documents they cannot open.

        Requirements
        - Results appear within 300 ms for 95% of queries.
        - Typos of one character should still match.
        - Results are ranked by title match first, then body match, then recency.
        - The search box is reachable with the keyboard shortcut slash.
        """,
        mode: :linguistic,
        genre: "spec"
      },
      %{
        id: "ho-spec-06",
        text: ~S"""
        Accessibility Requirements

        All new screens must meet the following before release:

        1. Every interactive element is reachable and operable with the keyboard alone.
        2. Focus order follows the visual order, and the focused element is always visible.
        3. Text contrast is at least 4.5:1 against its background.
        4. Images that carry meaning have text alternatives. Decorative images have empty alternatives.
        5. Form errors are announced to screen readers and are not conveyed by color alone.

        Verification: each release candidate is checked by a person using only a keyboard, and once per quarter by a person using a screen reader.
        """,
        mode: :linguistic,
        genre: "spec"
      },
      %{
        id: "ho-spec-07",
        text: ~S"""
        Data Retention Policy - Draft Spec

        Purpose
        Define how long customer data is kept and how it is removed.

        Rules
        - Active account data is kept for as long as the account is open.
        - After an account is closed, personal data is deleted within 30 days.
        - Backups containing deleted data are overwritten within 90 days.
        - Audit logs are kept for 12 months and contain no message content.

        Responsibilities
        Engineering implements deletion jobs. Support confirms deletion requests with the customer. Legal reviews this document yearly.
        """,
        mode: :linguistic,
        genre: "spec"
      },
      %{
        id: "ho-spec-08",
        text: ~S"""
        Invoice Numbering - Spec

        1. Invoice numbers are sequential per customer, starting at 1001.
        2. Numbers are never reused, even if an invoice is voided.
        3. A voided invoice keeps its number and is marked VOID on the PDF.
        4. Credit notes use a separate sequence with the prefix CN.
        5. The next number must be assigned at the moment the invoice is finalized, not when the draft is created.

        Edge case: two invoices finalized at the same instant must still receive different numbers.
        """,
        mode: :linguistic,
        genre: "spec"
      },
      %{
        id: "ho-spec-09",
        text: ~S"""
        # Webhook Delivery - Spec

        ## Overview
        The service notifies subscribers of events by sending an HTTP POST to the URL they registered.

        ## Requirements
        1. Each delivery carries a JSON body in the shape below.
        2. A delivery is considered successful when the receiver answers with any 2xx status within 10 seconds.
        3. Failed deliveries are retried up to 5 times with exponential backoff.
        4. Every request includes a signature header so the receiver can verify the sender.

        ## Payload

        ```json
        {
          "id": "evt_1001",
          "type": "invoice.paid",
          "created": "2026-04-02T10:15:00Z",
          "data": {
            "invoice_id": "inv_2040",
            "amount_cents": 4200
          }
        }
        ```

        ## Notes
        The id is stable across retries, so receivers can use it to ignore duplicates.
        """,
        mode: :mixed,
        genre: "spec"
      },
      %{
        id: "ho-spec-10",
        text: ~S"""
        # Team Invitations - API Spec

        ## Goal
        Let an admin invite a person by email and track whether the invite was accepted.

        ## Requirements
        1. Only admins can create invitations.
        2. An invitation expires after 7 days.
        3. Inviting an address that already belongs to a member returns an error.
        4. Re-inviting a pending address replaces the old invitation.

        ## Create an invitation

        Request:

        ```http
        POST /v1/invitations
        Content-Type: application/json

        { "email": "new.person@example.com", "role": "editor" }
        ```

        Response (201):

        ```json
        { "id": "inv_88", "status": "pending", "expires_at": "2026-04-17T00:00:00Z" }
        ```

        ## Errors
        - 403 when the caller is not an admin
        - 409 when the address is already a member
        """,
        mode: :mixed,
        genre: "spec"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # decision logs
  # ---------------------------------------------------------------------------

  defp decision_logs do
    [
      %{
        id: "ho-decision-01",
        text: ~S"""
        ## ADR-007: Use a single queue for all background jobs

        Status: Accepted
        Date: 2026-02-11

        Context
        We currently run three separate queues (emails, exports, imports). Each has its own workers and its own alerts. Two of them are almost always idle.

        Decision
        We will consolidate onto one queue with priority levels. Emails get the highest priority, exports the lowest.

        Consequences
        - Fewer things to monitor and scale.
        - A flood of exports could delay emails if priorities are misconfigured, so we add an alert on queue wait time.
        - Revisit if any single job type regularly exceeds 5 minutes.
        """,
        mode: :linguistic,
        genre: "decision-log"
      },
      %{
        id: "ho-decision-02",
        text: ~S"""
        Decision log

        2026-03-02  Pricing: keep the monthly price at $29 for now. Revisit after 200 paying accounts. (Alice, Bob)
        2026-03-09  Support hours: move to 9-5 local time, drop weekend coverage until the second hire. (Priya)
        2026-03-16  Brand: postpone the rename until after the launch. Too many moving parts. (all)
        """,
        mode: :linguistic,
        genre: "decision-log"
      },
      %{
        id: "ho-decision-03",
        text: ~S"""
        Decision: we will not build our own authentication.

        Reasoning: login, password reset, session handling and two-factor each look small and each turn out to be a quarter of work. A hosted identity provider covers all of them, and none of it differentiates our product.

        Trade-off: we accept a monthly fee and some loss of control over the login screen.

        Decided by: Alice and Tomas, after reviewing three providers.
        Date: 2026-01-22
        """,
        mode: :linguistic,
        genre: "decision-log"
      },
      %{
        id: "ho-decision-04",
        text: ~S"""
        ADR-012: Weekly releases instead of continuous deploys

        Options considered
        A. Deploy every merge to production.
        B. Deploy once a week, on Tuesday.
        C. Deploy on demand, with a manual approval.

        Chosen: B.

        Why: A needs test coverage we do not have yet. C leads to long gaps and large, risky releases. B gives a predictable rhythm and keeps each release small enough to roll back.

        Revisit: when the end-to-end suite runs in under 10 minutes.
        """,
        mode: :linguistic,
        genre: "decision-log"
      },
      %{
        id: "ho-decision-05",
        text: ~S"""
        DECISION - 2026-05-20
        We will ship the beta with email login only. Social login is deferred to v1.1.
        Why: each provider adds review time we don't have, and fewer than 10% of beta invitees asked for it.
        Owner: Priya
        Revisit: after beta feedback, mid-July
        """,
        mode: :linguistic,
        genre: "decision-log"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # standups
  # ---------------------------------------------------------------------------

  defp standups do
    [
      %{
        id: "ho-standup-01",
        text: ~S"""
        Standup - Wed

        Alice
        Yesterday: finished the invoice PDF layout, started on the tax lines.
        Today: tax lines, then review Bob's PR.
        Blockers: none.

        Bob
        Yesterday: fixed the timezone bug, wrote tests.
        Today: deploy to staging, look at the flaky upload test.
        Blockers: waiting on credentials for the staging bucket.
        """,
        mode: :linguistic,
        genre: "standup"
      },
      %{
        id: "ho-standup-02",
        text: ~S"""
        Priya
        Y: paired with Tomas on the search ranking
        T: write up findings, start on synonyms
        B: need a sample of real queries from support
        """,
        mode: :linguistic,
        genre: "standup"
      },
      %{
        id: "ho-standup-03",
        text: ~S"""
        Daily standup notes (Mon)
        - Alice: still on checkout redesign, should have a prototype tomorrow
        - Bob: out sick
        - Priya: on-call this week, 2 pages overnight, both were noisy alerts
        - Tomas: planning the offsite, venue shortlisted
        """,
        mode: :linguistic,
        genre: "standup"
      },
      %{
        id: "ho-standup-04",
        text: ~S"""
        Async standup - Thursday

        Done: merged the pagination change, answered 6 support threads.
        Doing: onboarding checklist, second pass on the copy.
        Blocked: nothing, but I would like a quick review on the checklist designs before lunch.
        """,
        mode: :linguistic,
        genre: "standup"
      },
      %{
        id: "ho-standup-05",
        text: ~S"""
        Standup 3/18
        Did: reviewed 3 PRs, fixed the typo in the onboarding copy that's been there since forever
        Doing: migration script for the legacy accounts
        Blocked: need a decision on whether to keep the old plan names
        """,
        mode: :linguistic,
        genre: "standup"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # postmortems
  # ---------------------------------------------------------------------------

  defp postmortems do
    [
      %{
        id: "ho-postmortem-01",
        text: ~S"""
        Postmortem: Checkout outage on March 12

        Summary
        For 47 minutes on March 12 (14:05-14:52 UTC), customers could not complete checkout. About 310 orders failed.

        Impact
        - 310 failed orders
        - Support received 58 tickets

        Timeline (UTC)
        14:05 Deploy of release 2026.03.12 finishes.
        14:11 Error rate on the checkout page rises above 20%.
        14:19 On-call is paged.
        14:34 Team identifies a missing database index on the new orders column.
        14:48 Index created, error rate falls.
        14:52 Incident closed.

        Root cause
        The release added a lookup on a column that had no index. Under production traffic the query took several seconds, which exhausted the connection pool.

        What went well
        - Paging worked, and the on-call responded within 5 minutes.

        What went wrong
        - Our staging data is too small to reveal slow queries.
        - The deploy had no automatic rollback on error-rate increase.

        Action items
        - Add an index check to code review (Priya, Mar 20)
        - Load-test staging with production-sized data (Bob, Apr 3)
        - Automatic rollback on elevated error rate (Tomas, Apr 10)
        """,
        mode: :linguistic,
        genre: "postmortem"
      },
      %{
        id: "ho-postmortem-02",
        text: ~S"""
        Incident review: delayed emails (blameless)

        What happened
        On April 3, welcome emails were delivered between 2 and 9 hours late for roughly 1,200 new users.

        Why it happened
        A bulk import by a customer filled the shared email queue. Welcome emails sat behind 40,000 import notifications.

        How we noticed
        A support agent mentioned that several new users had asked where their confirmation email was. Our own alerts did not fire because the queue was healthy, only slow.

        What we are changing
        1. Separate queues for transactional and bulk email.
        2. An alert on the age of the oldest message, not just the queue length.
        3. A rate limit on notifications triggered by imports.
        """,
        mode: :linguistic,
        genre: "postmortem"
      },
      %{
        id: "ho-postmortem-03",
        text: ~S"""
        Postmortem - duplicate records after the contact import

        Summary: the nightly import created duplicate contacts for about 3% of accounts between May 6 and May 9.

        Root cause: the matching step compared email addresses case-sensitively, so Alice@example.com and alice@example.com were treated as different people.

        Detection: a customer reported it on May 9. We should have caught it earlier. There was no check on the number of new records per run.

        Fix: matching is now case-insensitive and a cleanup script merged the existing duplicates.

        Follow-ups: add a sanity check that fails the run if new records exceed 5% of the total; write a regression test using mixed-case addresses.
        """,
        mode: :linguistic,
        genre: "postmortem"
      },
      %{
        id: "ho-postmortem-04",
        text: ~S"""
        Postmortem: expired certificate, Aug 21

        Impact: the public site showed a browser security warning for about 90 minutes. No data was exposed.

        Cause: the certificate renewal reminder was sent to a mailbox belonging to someone who left the company in June. Nobody else received it.

        Timeline
        09:10 First customer report arrives by chat.
        09:25 We confirm the certificate expired at 08:59.
        10:05 New certificate installed.
        10:40 Warnings stop appearing.

        Lessons
        - Renewal notices must go to a shared alias, not a person.
        - We need automatic renewal, with a separate alert seven days before expiry.
        - Offboarding should include a check of every system that sends mail to the departing person.
        """,
        mode: :linguistic,
        genre: "postmortem"
      },
      %{
        id: "ho-postmortem-05",
        text: ~S"""
        Retrospective on the missed launch date

        We planned to launch on September 1 and launched on September 22. Nobody was surprised on September 1 itself, which is the real problem: the slip was visible from mid-August and we did not say so.

        Contributing factors
        - Scope grew by about a third after the design review.
        - Two key people were out in August and we did not adjust the plan.
        - Status updates reported tasks done, not remaining risk.

        What we will do differently
        - Replace the weekly task list with a weekly risk list.
        - Any change in scope triggers a date review.
        - The person who owns the date is named in the plan, and it is not the project manager by default.
        """,
        mode: :linguistic,
        genre: "postmortem"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # runbooks
  # ---------------------------------------------------------------------------

  defp runbooks do
    [
      %{
        id: "ho-runbook-01",
        text: ~S"""
        Runbook: Restarting the worker pool

        When to use: the dashboard shows jobs waiting for more than 10 minutes and the workers report as idle.

        Steps
        1. Open the admin console and go to Workers.
        2. Check that no job is marked as running. If one is, wait up to 5 minutes for it to finish.
        3. Click Drain on each worker, then wait until the status changes to Stopped.
        4. Click Start on each worker, one at a time, and wait for it to report Healthy before starting the next.
        5. Confirm on the Jobs page that the waiting count starts to fall.

        If the count does not fall within 10 minutes, page the on-call engineer and attach a screenshot of the Workers page.
        """,
        mode: :linguistic,
        genre: "runbook"
      },
      %{
        id: "ho-runbook-02",
        text: ~S"""
        Runbook: Failed nightly backup

        Symptoms: the morning check email says the backup is missing or smaller than 80% of yesterday's.

        1. Look at the backup job history and note the error message.
        2. If the error mentions storage quota, ask the infrastructure owner to raise the quota, then trigger the backup again by hand.
        3. If the error mentions the database being unreachable, check the status page for the database provider before doing anything else.
        4. After a successful manual run, verify the new backup by restoring it into the scratch environment and opening the app.
        5. Write a short note in the incident channel with the cause and the time of the successful backup.

        Do not delete older backups while the problem is open.
        """,
        mode: :linguistic,
        genre: "runbook"
      },
      %{
        id: "ho-runbook-03",
        text: ~S"""
        Runbook: Onboarding a new support agent

        Before day one
        - Create their accounts for the help desk and the team chat.
        - Add them to the support rota, shadow only for the first week.

        Day one
        1. Walk through the five most common ticket types and how we answer them.
        2. Have them read ten closed tickets, rated good by customers.
        3. Pair them with a buddy who answers tickets with them looking on.

        End of week one
        - Review three tickets they answered, with their buddy present.
        - Agree what they will handle alone next week.
        """,
        mode: :linguistic,
        genre: "runbook"
      },
      %{
        id: "ho-runbook-04",
        text: ~S"""
        # Runbook: Log disk almost full

        Use this when the alert "disk usage above 90% on logs volume" fires.

        ## 1. Confirm

        ```bash
        df -h /var/log
        du -sh /var/log/* | sort -h | tail -5
        ```

        If a single file is far larger than the others, it is probably a runaway logger.

        ## 2. Free space safely

        ```bash
        sudo journalctl --vacuum-time=7d
        sudo gzip /var/log/app/app.log.1
        ```

        Do not delete the active log file. Truncating it can hide the cause.

        ## 3. Find the cause

        Look at the last 100 lines of the large file. If the same error repeats, open a ticket with the first and last occurrence.

        ## 4. Close out
        Post the final disk usage in the incident channel.
        """,
        mode: :mixed,
        genre: "runbook"
      },
      %{
        id: "ho-runbook-05",
        text: ~S"""
        Runbook: Restore the database from the latest snapshot

        Only do this with approval from the on-call lead. It replaces all current data.

        1. Stop the application so nothing writes during the restore:

           ```
           systemctl stop app
           ```

        2. List the available snapshots and pick the newest one that predates the problem:

           ```
           backup-tool list --env production
           ```

        3. Restore it into a new database, not over the old one:

           ```
           backup-tool restore --snapshot snap-0412 --target app_restored
           ```

        4. Point the application at the restored database in the config file and start it again.
        5. Verify the last order in the app matches the last order you expect, then announce the restore in the incident channel.

        Keep the old database untouched for at least 7 days.
        """,
        mode: :mixed,
        genre: "runbook"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # plans
  # ---------------------------------------------------------------------------

  defp plans do
    [
      %{
        id: "ho-plan-01",
        text: ~S"""
        Website Redesign - Plan

        Objective: launch a redesigned marketing site by the end of June without a drop in signups.

        Phase 1 (weeks 1-2): research
        - Review analytics for the ten most visited pages.
        - Interview five recent customers about how they found us.

        Phase 2 (weeks 3-5): design
        - Wireframes for home, pricing, and product pages.
        - Review with sales before visual design starts.

        Phase 3 (weeks 6-8): build and test
        - Build in the staging environment, move content page by page.
        - Redirect map for every old URL.

        Phase 4 (week 9): launch
        - Launch on a Tuesday morning, monitor signups for two weeks.

        Dependencies: copywriter available from week 3, photography done by week 5.
        Success: signup rate within 5% of the previous three-month average, page load under 2 seconds.
        """,
        mode: :linguistic,
        genre: "plan"
      },
      %{
        id: "ho-plan-02",
        text: ~S"""
        Plan for this week

        Monday: finish the proposal draft, send to Alice for comments.
        Tuesday: customer calls (two in the morning), update the pipeline afterwards.
        Wednesday: no meetings. Write the onboarding guide.
        Thursday: review designs with Bob, prepare the board update.
        Friday: board update by noon, then tidy the backlog.

        If anything slips, the proposal comes first.
        """,
        mode: :linguistic,
        genre: "plan"
      },
      %{
        id: "ho-plan-03",
        text: ~S"""
        Launch checklist and plan

        T-14 days
        - Freeze the feature list
        - Finish the help center articles
        T-7 days
        - Run the full test pass
        - Brief support on known issues
        T-2 days
        - Send the announcement draft for approval
        - Confirm rollback owner and procedure
        Launch day
        - Release at 10:00, announce at 11:00 once metrics look normal
        T+7 days
        - Review signups, support volume and bugs reported, decide what is next
        """,
        mode: :linguistic,
        genre: "plan"
      },
      %{
        id: "ho-plan-04",
        text: ~S"""
        Migration plan: moving customer files to the new storage

        Goal: all customer files in the new storage by the end of the quarter, with no downtime and no lost files.

        Approach: copy first, switch later.
        1. Copy all existing files to the new storage in the background, oldest first.
        2. Keep both stores in sync for new uploads through a dual write.
        3. Compare file counts and checksums per customer, and fix differences.
        4. Switch reads to the new store for internal accounts, then 10% of customers, then everyone.
        5. Keep the old store read-only for 30 days, then remove it.

        Risks: copy speed (mitigation: run during off-peak hours), missed files (mitigation: checksum comparison before every switch).
        """,
        mode: :linguistic,
        genre: "plan"
      },
      %{
        id: "ho-plan-05",
        text: ~S"""
        Q4 Hiring Plan

        Objective: grow the team from 8 to 11 by December 15.

        Priorities
        1. A senior backend engineer (start by November 1)
        2. A support specialist (start by November 15)
        3. A part-time designer (start by December 1)

        Sequence: post the roles this week, first screening calls by the end of the month, final interviews in the first half of October.

        Dependencies: budget approval from Alice, a revised interview guide from Priya.

        Success criteria: all three offers accepted, no more than 45 days from posting to offer for each role.
        """,
        mode: :linguistic,
        genre: "plan"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # briefs
  # ---------------------------------------------------------------------------

  defp briefs do
    [
      %{
        id: "ho-brief-01",
        text: ~S"""
        Design Brief: Customer Portal Login

        Objective
        Make it obvious to returning customers how to sign in, and to new customers how to request access.

        Key messages
        - Signing in takes less than ten seconds.
        - Help is one click away.

        Audience
        Small business owners, mostly on phones, often interrupted.

        Deliverables
        Mobile and desktop mockups of the login and request-access screens.

        Action and owner
        Bob drafts two directions by Friday. Alice picks one on Monday.

        Supporting links
        Current screens and analytics: https://example.com/docs/portal-login
        """,
        mode: :linguistic,
        genre: "brief"
      },
      %{
        id: "ho-brief-02",
        text: ~S"""
        Brief for the board - April

        Objective: get approval to extend the pilot to two more regions.

        Key messages
        1. The pilot retained 82% of accounts after 90 days, against a goal of 70%.
        2. Support cost per account is flat even as the number of accounts grew.
        3. The extension needs one more hire and about 20% more budget.

        Ask: a yes or no on the extension at the April meeting.
        Owner: Alice presents, Priya provides the retention numbers.
        """,
        mode: :linguistic,
        genre: "brief"
      },
      %{
        id: "ho-brief-03",
        text: ~S"""
        Contractor brief: illustrations for the help center

        We need eight simple spot illustrations for help center articles. Style: flat, friendly, two accent colors plus neutrals. No people with faces.

        Topics: getting started, inviting a team, billing, exports, notifications, security, integrations, troubleshooting.

        Format: editable vector files plus PNG exports at 800 pixels wide.
        Timeline: first two sketches by the 12th, all final files by the 30th.
        Contact: Tomas (tomas@example.com). Questions are welcome at any point.
        """,
        mode: :linguistic,
        genre: "brief"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # changelogs
  # ---------------------------------------------------------------------------

  defp changelogs do
    [
      %{
        id: "ho-changelog-01",
        text: ~S"""
        # Changelog

        ## 1.4.0 - 2026-03-02

        ### Added
        - Dark mode for the dashboard.
        - Bulk archive for projects.

        ### Changed
        - The default page size on lists is now 50.

        ### Fixed
        - Dates in exports now use the account timezone.
        - Fixed a crash when opening a project with no members.

        ## 1.3.2 - 2026-02-10

        ### Fixed
        - Invitation emails no longer show the wrong team name.
        """,
        mode: :linguistic,
        genre: "changelog"
      },
      %{
        id: "ho-changelog-02",
        text: ~S"""
        v2.3.1 (2026-04-08)
        - Fixed: uploads over 100 MB sometimes stalled at 99%.
        - Fixed: the unread badge did not clear after reading the last message.
        - Improved: search is about 30% faster on large workspaces.
        - Known issue: the print layout cuts off the last column in landscape mode.
        """,
        mode: :linguistic,
        genre: "changelog"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # context-free acknowledgements (linguistic, no genre)
  # ---------------------------------------------------------------------------

  defp acknowledgements do
    [
      %{id: "ho-ack-01", text: "ok", mode: :linguistic, genre: nil},
      %{id: "ho-ack-02", text: "thanks!", mode: :linguistic, genre: nil},
      %{id: "ho-ack-03", text: "👍", mode: :linguistic, genre: nil},
      %{id: "ho-ack-04", text: "got it, thx", mode: :linguistic, genre: nil},
      %{id: "ho-ack-05", text: "no worries", mode: :linguistic, genre: nil}
    ]
  end

  # ---------------------------------------------------------------------------
  # code
  # ---------------------------------------------------------------------------

  defp code do
    [
      %{
        id: "ho-code-01",
        text: ~S'''
        defmodule Counter do
          use GenServer

          def start_link(initial \\ 0) do
            GenServer.start_link(__MODULE__, initial, name: __MODULE__)
          end

          def increment(by \\ 1), do: GenServer.cast(__MODULE__, {:increment, by})
          def value, do: GenServer.call(__MODULE__, :value)

          @impl true
          def init(initial), do: {:ok, initial}

          @impl true
          def handle_cast({:increment, by}, state), do: {:noreply, state + by}

          @impl true
          def handle_call(:value, _from, state), do: {:reply, state, state}
        end
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-02",
        text: ~S'''
        defmodule Greeter do
          @moduledoc """
          Builds greeting messages.
          """

          @doc """
          Returns a greeting for the given name.

          ## Examples

              iex> Greeter.hello("Ana")
              "Hello, Ana!"
          """
          def hello(name) when is_binary(name) do
            "Hello, #{name}!"
          end

          def hello(_), do: {:error, :invalid_name}
        end
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-03",
        text: ~S'''
        import time


        class RateLimiter:
            """Simple token bucket rate limiter."""

            def __init__(self, capacity, refill_per_sec):
                self.capacity = capacity
                self.tokens = capacity
                self.refill_per_sec = refill_per_sec
                self.last = time.monotonic()

            def allow(self):
                """Return True if a request may proceed."""
                now = time.monotonic()
                elapsed = now - self.last
                self.last = now
                self.tokens = min(self.capacity, self.tokens + elapsed * self.refill_per_sec)
                if self.tokens >= 1:
                    self.tokens -= 1
                    return True
                return False
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-04",
        text: ~S'''
        #!/usr/bin/env python3
        import argparse
        import csv
        import sys


        def main():
            parser = argparse.ArgumentParser(description="Sum a column in a CSV file")
            parser.add_argument("path")
            parser.add_argument("--column", default="amount")
            args = parser.parse_args()

            total = 0.0
            with open(args.path, newline="") as fh:
                for row in csv.DictReader(fh):
                    total += float(row[args.column])

            print(f"{total:.2f}")
            return 0


        if __name__ == "__main__":
            sys.exit(main())
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-05",
        text: ~S'''
        async function fetchUser(id) {
          const res = await fetch(`/api/users/${id}`);
          if (!res.ok) {
            throw new Error(`Request failed: ${res.status}`);
          }
          const data = await res.json();
          return { id: data.id, name: data.name };
        }

        fetchUser(42).then(console.log).catch(console.error);
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-06",
        text: ~S'''
        const express = require('express');
        const app = express();
        const items = [];

        app.use(express.json());

        app.get('/health', (req, res) => {
          res.json({ status: 'ok', uptime: process.uptime() });
        });

        app.post('/items', (req, res) => {
          const { name, price } = req.body;
          if (!name || typeof price !== 'number') {
            return res.status(400).json({ error: 'invalid payload' });
          }
          items.push({ id: items.length + 1, name, price });
          res.status(201).json(items[items.length - 1]);
        });

        app.listen(3000);
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-07",
        text: ~S'''
        interface Invoice {
          id: string;
          total: number;
          currency: 'USD' | 'EUR';
          paid: boolean;
        }

        export function unpaidTotal(invoices: Invoice[]): number {
          return invoices
            .filter((inv) => !inv.paid)
            .reduce((sum, inv) => sum + inv.total, 0);
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-08",
        text: ~S'''
        import { useState } from 'react';

        type Props = { label: string; onToggle?: (on: boolean) => void };

        export function Toggle({ label, onToggle }: Props) {
          const [on, setOn] = useState(false);
          return (
            <button
              aria-pressed={on}
              onClick={() => {
                setOn(!on);
                onToggle?.(!on);
              }}
            >
              {label}: {on ? 'on' : 'off'}
            </button>
          );
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-09",
        text: ~S'''
        package main

        import (
            "encoding/json"
            "log"
            "net/http"
        )

        type response struct {
            Message string `json:"message"`
        }

        func hello(w http.ResponseWriter, r *http.Request) {
            w.Header().Set("Content-Type", "application/json")
            json.NewEncoder(w).Encode(response{Message: "hello"})
        }

        func main() {
            http.HandleFunc("/hello", hello)
            log.Fatal(http.ListenAndServe(":8080", nil))
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-10",
        text: ~S'''
        type Stack[T any] struct {
            items []T
        }

        func (s *Stack[T]) Push(v T) {
            s.items = append(s.items, v)
        }

        func (s *Stack[T]) Pop() (T, bool) {
            var zero T
            if len(s.items) == 0 {
                return zero, false
            }
            v := s.items[len(s.items)-1]
            s.items = s.items[:len(s.items)-1]
            return v, true
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-11",
        text: ~S'''
        #[derive(Debug, Clone)]
        pub struct Point {
            pub x: f64,
            pub y: f64,
        }

        impl Point {
            pub fn new(x: f64, y: f64) -> Self {
                Point { x, y }
            }

            pub fn distance(&self, other: &Point) -> f64 {
                ((self.x - other.x).powi(2) + (self.y - other.y).powi(2)).sqrt()
            }
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-12",
        text: ~S'''
        use std::collections::HashMap;

        fn main() {
            let mut counts: HashMap<String, usize> = HashMap::new();
            for word in "the quick brown fox jumps over the lazy dog the end".split_whitespace() {
                *counts.entry(word.to_string()).or_insert(0) += 1;
            }
            match counts.get("the") {
                Some(n) => println!("the appears {} times", n),
                None => println!("not found"),
            }
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-13",
        text: ~S'''
        package com.example.shop;

        import java.util.ArrayList;
        import java.util.List;

        public class Cart {
            private final List<Item> items = new ArrayList<>();

            public void add(Item item) {
                items.add(item);
            }

            public double total() {
                double sum = 0;
                for (Item item : items) {
                    sum += item.getPrice() * item.getQuantity();
                }
                return sum;
            }
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-14",
        text: ~S'''
        List<String> names = users.stream()
            .filter(u -> u.isActive())
            .map(User::getName)
            .sorted()
            .collect(Collectors.toList());
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-15",
        text: ~S'''
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>

        char *duplicate(const char *src) {
            size_t len = strlen(src);
            char *copy = malloc(len + 1);
            if (copy == NULL) {
                return NULL;
            }
            memcpy(copy, src, len + 1);
            return copy;
        }

        int main(void) {
            char *s = duplicate("hello");
            printf("%s\n", s);
            free(s);
            return 0;
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-16",
        text: ~S'''
        typedef struct Node {
            int value;
            struct Node *next;
        } Node;

        Node *push(Node *head, int value) {
            Node *n = (Node *)malloc(sizeof(Node));
            n->value = value;
            n->next = head;
            return n;
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-17",
        text: ~S'''
        using System;
        using System.Collections.Generic;

        namespace Inventory
        {
            public class Warehouse
            {
                private readonly Dictionary<string, int> _stock = new();

                public void Add(string sku, int qty)
                {
                    if (_stock.ContainsKey(sku)) _stock[sku] += qty;
                    else _stock[sku] = qty;
                }

                public int Count(string sku) => _stock.TryGetValue(sku, out var n) ? n : 0;
            }
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-18",
        text: ~S'''
        var expensive = products
            .Where(p => p.Price > 100m)
            .OrderByDescending(p => p.Price)
            .Select(p => new { p.Name, p.Price })
            .ToList();
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-19",
        text: ~S'''
        <?php

        namespace App\Services;

        class Mailer
        {
            private string $from;

            public function __construct(string $from)
            {
                $this->from = $from;
            }

            public function send(string $to, string $subject, string $body): bool
            {
                $headers = "From: {$this->from}\r\n";
                return mail($to, $subject, $body, $headers);
            }
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-20",
        text: ~S'''
        <?php
        $items = ['apple' => 3, 'pear' => 5, 'plum' => 2];
        foreach ($items as $name => $count) {
            echo "$name: $count\n";
        }
        echo array_sum($items) . PHP_EOL;
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-21",
        text: ~S'''
        data class User(val id: Int, val name: String, val email: String?)

        fun greet(user: User): String {
            val suffix = user.email?.let { " <$it>" } ?: ""
            return "Hello, ${user.name}$suffix"
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-22",
        text: ~S'''
        import kotlinx.coroutines.*

        fun main() = runBlocking {
            val jobs = List(3) { i ->
                launch {
                    delay(100L * (i + 1))
                    println("task $i done")
                }
            }
            jobs.joinAll()
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-23",
        text: ~S'''
        struct Temperature {
            var celsius: Double

            var fahrenheit: Double {
                return celsius * 9 / 5 + 32
            }
        }

        let t = Temperature(celsius: 21.5)
        print(t.fahrenheit)
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-24",
        text: ~S'''
        func parseAge(_ input: String) -> Int? {
            guard let value = Int(input), value >= 0 else {
                return nil
            }
            return value
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-25",
        text: ~S'''
        class Account
          attr_reader :balance

          def initialize(balance = 0)
            @balance = balance
          end

          def deposit(amount)
            raise ArgumentError, "amount must be positive" unless amount.positive?
            @balance += amount
          end
        end
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-26",
        text: ~S'''
        names = %w[ana bruno carla]
        names.each_with_index do |name, i|
          puts "#{i + 1}. #{name.capitalize}"
        end

        squares = (1..5).map { |n| n * n }
        puts "Squares: #{squares.join(', ')}"
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-27",
        text: ~S'''
        SELECT c.id,
               c.name,
               COUNT(o.id) AS order_count,
               COALESCE(SUM(o.total), 0) AS lifetime_value
        FROM customers c
        LEFT JOIN orders o ON o.customer_id = c.id
        WHERE c.created_at >= '2026-01-01'
        GROUP BY c.id, c.name
        HAVING COUNT(o.id) > 0
        ORDER BY lifetime_value DESC
        LIMIT 20;
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-28",
        text: ~S'''
        CREATE TABLE invoices (
            id           BIGSERIAL PRIMARY KEY,
            customer_id  BIGINT NOT NULL REFERENCES customers(id),
            amount_cents INTEGER NOT NULL CHECK (amount_cents >= 0),
            status       TEXT NOT NULL DEFAULT 'draft',
            issued_at    TIMESTAMPTZ,
            created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
        );

        CREATE INDEX idx_invoices_customer ON invoices (customer_id);
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-29",
        text: ~S'''
        #!/usr/bin/env bash
        set -euo pipefail

        BACKUP_DIR="${1:-/tmp/backups}"
        STAMP=$(date +%Y%m%d-%H%M%S)

        mkdir -p "$BACKUP_DIR"
        tar -czf "$BACKUP_DIR/site-$STAMP.tar.gz" ./site
        echo "Backup written to $BACKUP_DIR/site-$STAMP.tar.gz"
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-30",
        text: ~S'''
        log() { echo "[$(date +%T)] $*"; }

        for f in *.log; do
          if [ -s "$f" ]; then
            log "compressing $f"
            gzip "$f"
          else
            rm -f "$f"
          fi
        done
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-31",
        text: ~S'''
        $files = Get-ChildItem -Path .\logs -Filter *.log
        foreach ($file in $files) {
            if ($file.LastWriteTime -lt (Get-Date).AddDays(-30)) {
                Remove-Item $file.FullName -WhatIf
            }
        }
        Write-Host "Checked $($files.Count) files"
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-32",
        text: ~S'''
        function Get-DiskUsage {
            param(
                [string]$Path = "C:\",
                [int]$Top = 5
            )
            Get-ChildItem $Path -Directory |
                ForEach-Object {
                    $bytes = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object Length -Sum).Sum
                    [PSCustomObject]@{
                        Name   = $_.Name
                        SizeMB = [math]::Round($bytes / 1MB, 1)
                    }
                } |
                Sort-Object SizeMB -Descending |
                Select-Object -First $Top
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-33",
        text: ~S'''
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Landing</title>
          <link rel="stylesheet" href="styles.css">
        </head>
        <body>
          <header>
            <h1>Welcome</h1>
            <nav>
              <a href="/about">About</a>
              <a href="/contact">Contact</a>
            </nav>
          </header>
          <main>
            <p>This is a simple page.</p>
          </main>
          <script src="app.js"></script>
        </body>
        </html>
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-34",
        text: ~S'''
        <form action="/subscribe" method="post">
          <label for="email">Email address</label>
          <input type="email" id="email" name="email" required>
          <label>
            <input type="checkbox" name="weekly" checked> Weekly digest
          </label>
          <button type="submit">Subscribe</button>
        </form>
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-35",
        text: ~S'''
        :root {
          --brand: #2d6cdf;
          --radius: 6px;
        }

        .card {
          background: #fff;
          border: 1px solid #e3e6ea;
          border-radius: var(--radius);
          padding: 1rem 1.25rem;
          box-shadow: 0 1px 2px rgba(0, 0, 0, 0.06);
        }

        .card:hover {
          border-color: var(--brand);
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-36",
        text: ~S'''
        .grid {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 16px;
        }

        @media (max-width: 800px) {
          .grid {
            grid-template-columns: 1fr;
          }
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-37",
        text: ~S'''
        FROM node:20-alpine

        WORKDIR /app
        COPY package*.json ./
        RUN npm ci --omit=dev
        COPY . .

        ENV NODE_ENV=production
        EXPOSE 3000
        CMD ["node", "server.js"]
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-38",
        text: ~S'''
        # build stage
        FROM golang:1.22 AS build
        WORKDIR /src
        COPY go.mod go.sum ./
        RUN go mod download
        COPY . .
        RUN CGO_ENABLED=0 go build -o /out/server ./cmd/server

        # runtime stage
        FROM alpine:3.19
        RUN adduser -D app
        USER app
        COPY --from=build /out/server /usr/local/bin/server
        ENTRYPOINT ["server"]
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-39",
        text: ~S'''
        terraform {
          required_version = ">= 1.5"
        }

        variable "environment" {
          type    = string
          default = "staging"
        }

        resource "random_id" "suffix" {
          byte_length = 4
        }

        resource "local_file" "config" {
          filename = "${path.module}/out/${var.environment}-${random_id.suffix.hex}.conf"
          content  = "env = ${var.environment}\n"
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-40",
        text: ~S'''
        variable "instance_count" {
          description = "Number of instances to create"
          type        = number
          default     = 2
        }

        locals {
          names = [for i in range(var.instance_count) : "web-${i}"]
        }

        output "instance_names" {
          value = local.names
        }
        ''',
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-41",
        text: "const total = items.reduce((a, b) => a + b.price, 0);",
        mode: :code,
        genre: nil
      },
      %{id: "ho-code-42", text: "git log --oneline | head -5", mode: :code, genre: nil},
      %{
        id: "ho-code-43",
        text: "SELECT count(*) FROM users WHERE active = true;",
        mode: :code,
        genre: nil
      },
      %{
        id: "ho-code-44",
        text: ~S'''
        /*
         * Retry helper.
         *
         * We retry only on errors that are known to be transient. Anything else
         * (bad input, auth failures) fails immediately, because retrying those just
         * hides the real problem and makes the logs harder to read.
         *
         * The delay doubles after every attempt and is capped at maxDelayMs.
         */
        function retry(fn, attempts = 5, maxDelayMs = 8000) {
          // first attempt has no delay
          let delay = 250;
          return new Promise((resolve, reject) => {
            const run = (n) => {
              fn().then(resolve).catch((err) => {
                // give up when out of attempts or the error is permanent
                if (n >= attempts || !err.transient) return reject(err);
                setTimeout(() => run(n + 1), delay);
                delay = Math.min(delay * 2, maxDelayMs);
              });
            };
            run(1);
          });
        }
        ''',
        mode: :code,
        genre: nil
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # data
  # ---------------------------------------------------------------------------

  defp data do
    [
      %{
        id: "ho-data-01",
        text: ~S"""
        id,name,email,signup_date,plan
        1,Alice,alice@example.com,2026-01-04,pro
        2,Bob,bob@example.com,2026-01-09,free
        3,Priya,priya@example.com,2026-01-15,pro
        4,Tomas,tomas@example.com,2026-02-02,team
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-02",
        text: ~S"""
        sku,description,price,notes
        A-100,"Widget, small",4.50,"ships in 2 days"
        A-101,"Widget, large",7.25,
        B-200,"Gadget ""Pro"" edition",19.99,"back-ordered, see supplier"
        C-300,Cable (1m),2.10,"bulk pricing, 100+"
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-03",
        text: ~S"""
        datum;produkt;menge;preis
        2026-03-01;Apfel;12;0,45
        2026-03-01;Birne;8;0,60
        2026-03-02;Apfel;20;0,45
        2026-03-02;Kirsche;5;1,90
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-04",
        text: ~S"""
        timestamp,cpu,mem,disk
        2026-04-01T00:00:00Z,12.5,48.1,71.0
        2026-04-01T00:05:00Z,14.1,48.3,71.0
        2026-04-01T00:10:00Z,31.8,49.0,71.1
        2026-04-01T00:15:00Z,29.4,49.2,71.1
        2026-04-01T00:20:00Z,13.0,48.7,71.1
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-05",
        text: ~S"""
        id,comment
        1,"Great service, would recommend"
        2,"The delivery was late.
        The driver was friendly though."
        3,Fine
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-06",
        text:
          "name\tcity\tage\nAlice\tLisbon\t34\nBob\tPorto\t41\nPriya\tFaro\t29\nTomas\tBraga\t38\n",
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-07",
        text:
          "date\tevent\tcount\n2026-05-01\tlogin\t1240\n2026-05-01\tsignup\t87\n2026-05-02\tlogin\t1315\n2026-05-02\tsignup\t92\n2026-05-03\tlogin\t998\n",
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-08",
        text:
          "product\tregion\tq1\tq2\tq3\tq4\nwidget\tnorth\t120\t135\t150\t170\nwidget\tsouth\t90\t95\t100\t110\ngadget\tnorth\t60\t58\t75\t80\n",
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-09",
        text: ~S"""
        {
          "id": 42,
          "name": "Alice",
          "email": "alice@example.com",
          "roles": ["admin", "editor"],
          "address": {
            "city": "Lisbon",
            "country": "PT"
          },
          "active": true
        }
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-10",
        text: ~S"""
        {
          "name": "demo-app",
          "version": "1.2.0",
          "private": true,
          "scripts": {
            "start": "node server.js",
            "test": "jest"
          },
          "dependencies": {
            "express": "^4.18.0"
          }
        }
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-11",
        text: ~S"""
        {
          "service": "billing",
          "timeouts": {
            "connect_ms": 500,
            "read_ms": 3000
          },
          "retry": {
            "max_attempts": 4,
            "backoff": [100, 200, 400, 800]
          },
          "proxy": null,
          "features": {
            "invoices_v2": true,
            "credit_notes": false
          }
        }
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-12",
        text: ~S"""
        {
          "page": 2,
          "per_page": 3,
          "total": 11,
          "results": [
            { "id": 4, "title": "Quarterly report", "status": "draft" },
            { "id": 5, "title": "Team handbook", "status": "published" },
            { "id": 6, "title": "Launch checklist", "status": "published" }
          ]
        }
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-13",
        text: ~S"""
        {"id":7,"name":"Bob","tags":["a","b"],"score":0.92}
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-14",
        text: ~S"""
        {"event":"login","user":"priya","ts":1772541600,"ok":true,"meta":{"ip":"192.0.2.10","ua":"cli"}}
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-15",
        text: ~S"""
        {"status":"ok","data":{"items":[{"id":1,"qty":2},{"id":2,"qty":5}],"total":7}}
        """,
        mode: :data,
        genre: nil
      },
      %{id: "ho-data-16", text: "[1, 2, 3, 5, 8, 13, 21]", mode: :data, genre: nil},
      %{
        id: "ho-data-17",
        text: ~S"""
        ["red", "green", "blue", "yellow", "orange", "purple"]
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-18",
        text: ~S"""
        [
          {"sku": "A-100", "qty": 12, "price": 4.5},
          {"sku": "A-101", "qty": 0, "price": 7.25},
          {"sku": "B-200", "qty": 3, "price": 19.99}
        ]
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-19",
        text: ~S"""
        {"ts":"2026-05-01T10:00:00Z","level":"info","msg":"server started"}
        {"ts":"2026-05-01T10:00:05Z","level":"warn","msg":"slow query","ms":812}
        {"ts":"2026-05-01T10:00:09Z","level":"error","msg":"connection reset"}
        {"ts":"2026-05-01T10:00:10Z","level":"info","msg":"reconnected"}
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-20",
        text: ~S"""
        {"id":1,"text":"great product","label":"positive"}
        {"id":2,"text":"arrived broken","label":"negative"}
        {"id":3,"text":"it's okay","label":"neutral"}
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-21",
        text: ~S"""
        {"role":"user","content":"What is the capital of Portugal?"}
        {"role":"assistant","content":"Lisbon."}
        {"role":"user","content":"And of Spain?"}
        {"role":"assistant","content":"Madrid."}
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-22",
        text: ~S"""
        # application settings
        app:
          name: demo
          port: 8080
          debug: false

        # database
        database:
          host: localhost
          port: 5432
          pool: 10
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-23",
        text: ~S"""
        name: test
        on:
          push:
            branches: [main]
        jobs:
          build:
            runs-on: linux-small
            steps:
              - uses: actions/checkout@v4
              - run: make test
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-24",
        text: ~S"""
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: demo-config
        data:
          LOG_LEVEL: info
          FEATURE_X: "true"
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-25",
        text: ~S"""
        - name: Alice
          role: admin
        - name: Bob
          role: viewer
        - name: Priya
          role: editor
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-26",
        text: ~S"""
        [package]
        name = "demo"
        version = "0.3.1"
        edition = "2021"

        [dependencies]
        serde = "1.0"
        tokio = { version = "1", features = ["full"] }
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-27",
        text: ~S"""
        # server config
        title = "Example"

        [server]
        host = "0.0.0.0"
        port = 8080

        [[backends]]
        name = "primary"
        weight = 3

        [[backends]]
        name = "secondary"
        weight = 1
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-28",
        text: ~S"""
        [project]
        name = "reportgen"
        version = "2.1.0"
        requires-python = ">=3.10"
        dependencies = ["pandas>=2.0", "jinja2"]

        [tool.formatter]
        line-length = 100
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-29",
        text: ~S"""
        | Name  | Role     | Team     |
        |-------|----------|----------|
        | Alice | Engineer | Platform |
        | Bob   | Designer | Growth   |
        | Priya | PM       | Growth   |
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-30",
        text: ~S"""
        | Month | Visits | Signups | Rate  |
        |:------|-------:|--------:|------:|
        | Jan   | 12,400 |     310 | 2.5%  |
        | Feb   | 13,950 |     372 | 2.7%  |
        | Mar   | 15,100 |     453 | 3.0%  |
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-31",
        text: ~S"""
        | Setting | Default | Description |
        | --- | --- | --- |
        | timeout | 30 | Seconds to wait for a response before giving up |
        | retries | 3 | Number of times a failed request is repeated |
        | verbose | false | Print every request and response to the console |
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-32",
        text: ~S"""
        <?xml version="1.0" encoding="UTF-8"?>
        <orders>
          <order id="1001">
            <customer>Alice</customer>
            <total currency="USD">42.50</total>
          </order>
          <order id="1002">
            <customer>Bob</customer>
            <total currency="EUR">17.00</total>
          </order>
        </orders>
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-33",
        text: ~S"""
        <urlset>
          <url><loc>https://example.com/</loc><lastmod>2026-04-01</lastmod></url>
          <url><loc>https://example.com/pricing</loc><lastmod>2026-03-18</lastmod></url>
          <url><loc>https://example.com/contact</loc><lastmod>2026-02-27</lastmod></url>
        </urlset>
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-34",
        text: ~S"""
        APP_ENV=production
        LOG_LEVEL=info
        PORT=8080
        CACHE_TTL=300
        WORKERS=4
        """,
        mode: :data,
        genre: nil
      },
      %{
        id: "ho-data-35",
        text: ~S"""
        [general]
        name = demo
        retries = 3

        [paths]
        data = /var/lib/demo
        cache = /var/cache/demo
        """,
        mode: :data,
        genre: nil
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # mixed (prose plus a substantive code block, table or image)
  # ---------------------------------------------------------------------------

  defp mixed do
    [
      %{
        id: "ho-mixed-01",
        text: ~S'''
        # datefmt

        A tiny library for formatting dates in plain English. It has no dependencies and works on Python 3.9 and newer.

        ## Install

        ```bash
        pip install datefmt
        ```

        ## Usage

        Call `humanize()` with a datetime and it returns a short phrase:

        ```python
        from datetime import datetime, timedelta
        from datefmt import humanize

        print(humanize(datetime.now() - timedelta(minutes=5)))  # "5 minutes ago"
        print(humanize(datetime.now() + timedelta(days=2)))     # "in 2 days"
        ```

        ## Contributing

        Open an issue before sending a large change. Tests live in the tests folder and run with the usual test runner.

        ## License

        MIT
        ''',
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-02",
        text: ~S"""
        Quarterly support summary

        First response time improved in every channel this quarter, with chat showing the largest gain. Email remains the slowest channel, which is expected given our staffing, but the gap is narrowing.

        | Channel | Q1 (hrs) | Q2 (hrs) | Change |
        |---------|---------:|---------:|-------:|
        | Chat    | 1.8      | 0.6      | -67%   |
        | Email   | 19.0     | 6.2      | -67%   |
        | Phone   | 0.3      | 0.3      | 0%     |

        The main driver was routing billing questions directly to a dedicated queue. We expect further gains once weekend coverage starts in Q3, and we will report the weekend numbers separately so they do not distort the averages.
        """,
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-03",
        text: ~S"""
        Bug on the settings page: the save button overlaps the footer on narrow screens.

        ![settings page screenshot](./images/settings-overlap.png)

        Seen on a 360px wide viewport. On wider screens the layout is fine. Probably the footer is fixed-position and the form has no bottom padding. Should be a quick fix, but worth checking the other settings tabs too since they share the same layout component.
        """,
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-04",
        text: ~S'''
        Retrying failed requests

        Network calls fail for boring reasons: a dropped connection, a server restarting, a rate limit. Most of these are temporary, so a small retry loop with a growing delay fixes the majority of them without any user-visible error.

        Here is a minimal version in Python:

        ```python
        import time
        import requests

        def get_with_retry(url, attempts=4):
            delay = 0.5
            for i in range(attempts):
                try:
                    resp = requests.get(url, timeout=5)
                    resp.raise_for_status()
                    return resp
                except requests.RequestException:
                    if i == attempts - 1:
                        raise
                    time.sleep(delay)
                    delay *= 2
        ```

        Two things to notice. The delay doubles each time, so a struggling server gets breathing room. And the last failure is re-raised, so the caller still learns when something is really wrong.
        ''',
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-05",
        text: ~S"""
        Hi all, I'm seeing a crash when a customer places an order with an empty cart. Here is the stack trace from the logs:

        ```
        Traceback (most recent call last):
          File "app/orders.py", line 88, in create_order
            total = sum(item.price for item in cart.items) / len(cart.items)
        ZeroDivisionError: division by zero
        ```

        It looks like we divide by the number of items to compute an average, and nothing guards the empty case. It only happens through the mobile app, because the web checkout blocks empty carts in the browser.

        Steps to reproduce: open the app, add an item, remove it, tap Place Order. I think the fix is a check at the top of the function, but we should also stop the button from being enabled.
        """,
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-06",
        text: ~S"""
        ## Fetching a project

        Returns a single project by its identifier. The caller must be a member of the project's workspace.

        Example request:

        ```bash
        curl -s https://api.example.com/v1/projects/prj_204 \
          -H "Authorization: Bearer $TOKEN"
        ```

        Example response:

        ```json
        {
          "id": "prj_204",
          "name": "Website redesign",
          "status": "active",
          "members": 6,
          "created_at": "2026-02-14T09:30:00Z"
        }
        ```

        If the project does not exist, or you are not a member, the response is a 404 with an error message in the body. We return the same response in both cases so that project ids cannot be probed.
        """,
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-07",
        text: ~S"""
        Finding your best customers with SQL

        A common first question is who your biggest customers are. You can answer it with one query that joins customers to their orders and adds up the totals:

        ```sql
        SELECT c.name, SUM(o.total) AS spent
        FROM customers c
        JOIN orders o ON o.customer_id = c.id
        GROUP BY c.name
        ORDER BY spent DESC
        LIMIT 10;
        ```

        The join keeps only customers who have at least one order, which is what you want here. If you also want customers with no orders, switch to a left join and wrap the sum in a function that turns nulls into zero. Run it on a copy of the data first if the orders table is large.
        """,
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-08",
        text: ~S"""
        Subject: Nightly job failing since Tuesday

        Hi Bob,

        The nightly sync has failed three nights in a row. I pulled the relevant lines from the log:

        ```
        2026-06-09 02:00:11 INFO  sync started
        2026-06-09 02:00:42 WARN  upstream slow (3120 ms)
        2026-06-09 02:01:15 ERROR upstream returned 503, giving up after 3 attempts
        2026-06-09 02:01:15 INFO  sync aborted, 0 records written
        ```

        It always dies on the upstream call, never on our side. I suspect they changed something around Tuesday, because before that the same call took under a second. Could you ask them whether they changed rate limits or moved servers?

        In the meantime I'll run the sync by hand each morning so the reports stay current.

        Thanks,
        Priya
        """,
        mode: :mixed,
        genre: "email"
      },
      %{
        id: "ho-mixed-09",
        text: ~S"""
        Meeting notes - product sync, Thursday

        We agreed to cut the reporting feature from the first release. It is the largest piece of work and only two of the pilot customers asked for it. Everything else stays in scope. Alice will tell the pilot customers this week, with a date for when reporting arrives.

        Action items:

        | Owner | Task | Due |
        |-------|------|-----|
        | Alice | Tell pilot customers about the scope change | Fri |
        | Bob | Update the roadmap page | Mon |
        | Priya | Re-estimate the remaining work | Wed |

        Next sync is the same time next week.
        """,
        mode: :mixed,
        genre: "note"
      },
      %{
        id: "ho-mixed-10",
        text: ~S"""
        How we configure environments

        Each environment gets its own file, and anything that differs between environments lives there rather than in code. The production file looks like this:

        ```yaml
        environment: production
        database:
          host: db.internal.example.com
          pool_size: 20
        cache:
          ttl_seconds: 300
        logging:
          level: warn
        ```

        Secrets are never stored in these files. They are injected when the service starts, and the files only reference their names. That keeps the configuration safe to review in a pull request, and it means a new teammate can read the whole setup without needing special access.
        """,
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-11",
        text: ~S"""
        hey @bob, getting this weird result from the helper you wrote, can you take a look?

        ```js
        const parsed = parseDuration("1h30m");
        console.log(parsed); // expected 5400, got 3600
        ```

        looks like it stops after the first unit. i tried `"90m"` and that works fine, so it's only when two units are combined. no rush, just flagging it :pray:
        """,
        mode: :mixed,
        genre: "message"
      },
      %{
        id: "ho-mixed-12",
        text: ~S"""
        How a request moves through the system

        A user request first reaches the gateway, which checks the session. If the session is valid the request is passed to the application, which reads from the database and, for slow lookups, from the cache first. Results are returned the same way they came in.

        ```mermaid
        sequenceDiagram
            participant U as User
            participant G as Gateway
            participant A as App
            participant C as Cache
            participant D as Database
            U->>G: request
            G->>A: validated request
            A->>C: lookup
            C-->>A: miss
            A->>D: query
            D-->>A: rows
            A-->>U: response
        ```

        The cache is the part most worth understanding, because most of our performance work has been about raising its hit rate.
        """,
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-13",
        text: ~S"""
        Feature flags

        We use flags to ship code before it is visible. A flag is just a named boolean, set per environment. To turn on the new invoice page for staging only, the flags file gets this entry:

        {
          "new_invoice_page": {
            "staging": true,
            "production": false
          }
        }

        Once a feature has been on in production for two weeks without problems, delete the flag and the old code path. Flags that outlive their purpose are one of the most common sources of confusing behavior, so we review the list at the start of every quarter.
        """,
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-14",
        text: ~S'''
        Question: how do I remove duplicates from a list but keep the original order?

        I have a list like this and I want the first occurrence of each item to stay in place:

        ```python
        items = ["b", "a", "b", "c", "a"]
        ```

        Converting to a set loses the order. What is the simplest way?

        Answer: in current Python versions dictionaries keep insertion order, so you can use the keys of a dictionary built from the list:

        ```python
        unique = list(dict.fromkeys(items))
        print(unique)  # ['b', 'a', 'c']
        ```

        This runs in linear time and needs no extra imports.
        ''',
        mode: :mixed,
        genre: nil
      },
      %{
        id: "ho-mixed-15",
        text: ~S"""
        Setting up a local copy of the project

        You need about ten minutes and a working Git installation. Start by cloning the repository and moving into it:

        ```bash
        git clone https://example.com/team/project.git
        cd project
        ```

        Next, create your local settings from the template, so you can change values without touching the shared file:

        ```bash
        cp settings.example.toml settings.toml
        ```

        Finally, start the development server. It reloads when you save a file, so you can leave it running while you work:

        ```bash
        make dev
        ```

        If the last step prints a port error, another program is probably using port 8080. Stop that program or change the port in your local settings.
        """,
        mode: :mixed,
        genre: nil
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # visual (images, SVG, diagram definitions)
  # ---------------------------------------------------------------------------

  defp visual do
    [
      %{
        id: "ho-visual-01",
        text: ~S"""
        ![Home screen](https://example.com/img/home.png)
        ![Settings](https://example.com/img/settings.png)
        ![Profile](https://example.com/img/profile.png)
        ![Checkout](https://example.com/img/checkout.png)
        """,
        mode: :visual,
        genre: nil
      },
      %{
        id: "ho-visual-02",
        text: "![Architecture overview](./diagrams/overview.png)",
        mode: :visual,
        genre: nil
      },
      %{
        id: "ho-visual-03",
        text: ~S"""
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10" fill="none" stroke="#333" stroke-width="2"/>
          <path d="M8 12l3 3 5-6" fill="none" stroke="#333" stroke-width="2"/>
        </svg>
        """,
        mode: :visual,
        genre: nil
      },
      %{
        id: "ho-visual-04",
        text: ~S"""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="120" viewBox="0 0 200 120">
          <rect x="10" y="60" width="30" height="50" fill="#4c78a8"/>
          <rect x="55" y="40" width="30" height="70" fill="#4c78a8"/>
          <rect x="100" y="20" width="30" height="90" fill="#4c78a8"/>
          <rect x="145" y="50" width="30" height="60" fill="#4c78a8"/>
          <line x1="5" y1="110" x2="195" y2="110" stroke="#999" stroke-width="1"/>
        </svg>
        """,
        mode: :visual,
        genre: nil
      },
      %{
        id: "ho-visual-05",
        text: ~S"""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 100">
          <defs>
            <linearGradient id="g" x1="0" y1="0" x2="1" y2="0">
              <stop offset="0%" stop-color="#ff7a59"/>
              <stop offset="100%" stop-color="#ffd166"/>
            </linearGradient>
          </defs>
          <rect width="300" height="100" rx="12" fill="url(#g)"/>
          <text x="150" y="58" font-size="24" text-anchor="middle" fill="#fff">Welcome</text>
        </svg>
        """,
        mode: :visual,
        genre: nil
      },
      %{
        id: "ho-visual-06",
        text: ~S"""
        flowchart TD
            A[Start] --> B{Signed in?}
            B -- Yes --> C[Show dashboard]
            B -- No --> D[Show login]
            D --> E[Enter credentials]
            E --> B
            C --> F[End]
        """,
        mode: :visual,
        genre: nil
      },
      %{
        id: "ho-visual-07",
        text: ~S"""
        sequenceDiagram
            participant C as Client
            participant S as Server
            participant Q as Queue
            C->>S: POST /orders
            S->>Q: enqueue order
            Q-->>S: ack
            S-->>C: 202 Accepted
            Q->>S: process order
            S-->>C: webhook order.completed
        """,
        mode: :visual,
        genre: nil
      },
      %{
        id: "ho-visual-08",
        text: ~S"""
        stateDiagram-v2
            [*] --> Draft
            Draft --> Review: submit
            Review --> Approved: approve
            Review --> Draft: request changes
            Approved --> Published: publish
            Published --> [*]
        """,
        mode: :visual,
        genre: nil
      },
      %{
        id: "ho-visual-09",
        text: ~S"""
        digraph deploy {
          rankdir=LR;
          node [shape=box, style=rounded];
          commit -> build -> test -> staging -> production;
          test -> build [label="fail", style=dashed];
        }
        """,
        mode: :visual,
        genre: nil
      },
      %{
        id: "ho-visual-10",
        text: ~S"""
        graph org {
          node [shape=ellipse];
          subgraph cluster_eng {
            label="Engineering";
            alice -- bob;
            alice -- priya;
          }
          subgraph cluster_ops {
            label="Operations";
            tomas -- dana;
          }
          alice -- tomas;
        }
        """,
        mode: :visual,
        genre: nil
      }
    ]
  end
end
