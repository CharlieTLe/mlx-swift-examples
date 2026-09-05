// Copyright © 2026 Apple Inc.

import Foundation
import MLXLMCommon

/// Every prompt string the app sends, and the sampling presets that go with them.
///
/// `version` is bumped whenever any string here changes. Cached output records the
/// version it was generated under, so a bump invalidates rather than silently
/// mixing yesterday's text with today's prompts.
enum Prompts {

    /// Bump on any change to a string in this file.
    ///
    /// Also bumped for a corpus re-parse that changes the rendered text, which this
    /// is the only lever for: `AnnotationCache.synopsis` keys on schema, prompt
    /// version and model ID, so nothing else would invalidate a scene summary
    /// written from lines that used to be misfiled as stage directions.
    ///
    /// 3: `Line.plainText` now strips Gutenberg's italic underscores from speech as
    /// well as from directions, so a cached annotation written before it was asked
    /// about `_Hic et ubique?_` rather than about `Hic et ubique?`. The passage digest
    /// covers the selected lines but not the BEFORE/AFTER window, so this is what
    /// invalidates the rest.
    ///
    /// 4: the gloss rule named `"quietus"` as its example, and the model lifted the
    /// word into passages that do not contain it — Voltemand's report of the Norway
    /// embassy was annotated with `"quietus" (release) is the key here`, and the
    /// follow-up list then offered to explain it. The example is now a schema rather
    /// than a word, plus an explicit "it has to be in the passage".
    ///
    /// 5: that was not binding enough — the model went on glossing words it had only
    /// read in the surrounding window, `thorns` and `glow-worm` from the Ghost's exit
    /// speech among them. Stating the constraint as a *check to run before writing*
    /// holds where stating it as a property of the word did not. Measured with
    /// `--benchmark --greedy` over the 13 sample passages: quoted single words that
    /// come from outside the selection fall from 5 of 24 to 2 of 15.
    ///
    /// Naming the request's own block labels — "gloss only words printed under
    /// SELECTED PASSAGE" — was tried first and rejected. It cut the glossing rather
    /// than aiming it (2 of 5 words left in the selection), and it taught the model
    /// the shape of the blocks: the Hamlet V.i annotation opened by transcribing the
    /// passage as `First Clown: …`, which is what the "never mention the context"
    /// rule below exists to prevent.
    ///
    /// 6: `&c.` is now read as `etc.` — 31 lines across 15 plays, one scene setting and
    /// six personae blurbs. A corpus re-parse this is the only lever for, exactly as 3
    /// was: the rendered text changed, so a cached annotation was written about a
    /// passage that read `Enter priests, &c, in procession`.
    ///
    /// 7: two breaches of the annotation's own contract, both fixed on the request's
    /// last line rather than in the instructions. That line was four words —
    /// "Annotate the selected passage." — against 500-1,000 tokens of verse, and it is
    /// the one position in the request where recency is free.
    ///
    /// The III.i soliloquy annotation opened by transcribing the passage back:
    /// `hamlet: to be, or not to be, that is the question…`. That is the failure note 5
    /// records the V.i annotation falling into, and the "never mention the context"
    /// rule was assumed to cover it. It does not — it forbids *naming* the blocks, not
    /// *reproducing* what is in them. `AnnotationPaneView.header` already echoes the
    /// selected lines directly above the commentary, so a transcription is the same
    /// text paid for twice, once in prefill and once in the reader's attention. Stated
    /// as a constraint on the first sentence, which is where it is broken, for the
    /// reason note 5 gives: a check to run while writing binds where a property of the
    /// output does not.
    ///
    /// The 90-150 word rule is separately ignored outright on a long selection. A
    /// double-click on the Ghost in I.v takes his whole contiguous run, 49 lines, and
    /// got 208 words assembled out of the hebenon and the "smooth body" in the middle
    /// of it rather than out of the farewell it ends on. Nothing was truncated — 208
    /// words is well inside what `maxTokens: 320` buys — so this is not a sampling
    /// problem. The model scales its answer to the passage, and the budget was tuned on
    /// passages a tenth the size. The request now restates the budget, and says what to
    /// spend it on, once the selection passes `longSelection`.
    ///
    /// 8: the model kept losing the speech situation. Across two graded passages:
    /// Claudius's "harlot's cheek" given to Hamlet and aimed at Ophelia; Hamlet's
    /// `[_Aside._]` answered as though said to Claudius's face; Ophelia's speech to
    /// her brother read as a warning to an absent Hamlet; Polonius described as
    /// watching a scene he enters two lines after the selection ends.
    ///
    /// Every one of those facts was already in the request, and correct. The I.iii
    /// `ON STAGE` block read exactly `Laertes, Ophelia`. What beat it was *position*:
    /// `[Enter Polonius.]` in the AFTER block and a scene summary naming Hamlet in
    /// five of its six sentences both sat nearer the end of the prompt than the
    /// on-stage list did, and a fact that holds later outranked a fact that holds now.
    /// So `THE MOMENT` restates the present situation last, where the competing
    /// material was winning from, and says the not-yet out loud instead of leaving it
    /// to be inferred from a block label. `ON STAGE` moved into it rather than being
    /// duplicated — it is computed `upTo:` the selection, so it was never
    /// scene-invariant and never belonged in the prefix.
    ///
    /// The worst of it was not the weights. The Hamlet I.ii summary this app wrote
    /// says the Ghost appears and confirms the murder, which happens in I.v; the
    /// annotation used it faithfully and every answer in that session inherited it.
    /// A 4B model compressing 284 lines into 90 words is the honest limit here and no
    /// instruction fixes it, so the summary is now labelled rough with the lines named
    /// as the authority — containment, not a cure. Chunking the summary is the real
    /// answer and is still the v2 that `synopsisLineLimit` describes.
    ///
    /// Also, on the same evidence: the gloss budget went on *watchman* and *pastor*
    /// while the two dead words in the passage went untouched, and arrived as a
    /// trailing dictionary paragraph — so the rule now aims at difficulty, sets a
    /// floor as well as a ceiling, and says inline. No example word is named, which
    /// note 4 is the reason for. The follow-up generator still leaked out-of-selection
    /// words that note 5 closed for the annotation (`unmaster'd importunity`, thirteen
    /// lines above the selection), so it carries the constraint too.
    ///
    /// 9: `THE MOMENT` asserted a negative the app cannot know. `ON STAGE` comes from
    /// the direction scan, which its own label has always called approximate, and
    /// "— and nobody else" promoted that to a claim that the stage holds no one else.
    /// Hamlet III.i is where it breaks: the King and Polonius withdraw under an
    /// `Exeunt` at line 61 and listen from concealment, so the scan drops them and the
    /// app would have told the model the stage was clear in the one scene whose whole
    /// point is that it is not. The clause now binds only where it has evidence —
    /// these are the people the directions record, add nobody the lines do not — which
    /// still keeps Polonius from being invented into I.iii, where he has not entered,
    /// without claiming absence anywhere. The instruction rule beside it said "only
    /// the people listed on stage are there" and had exactly the same defect, so it
    /// got the same edit.
    ///
    /// 10: five changes, all of them decided by measurement rather than by argument,
    /// after two versions that moved the annotation's form and not its substance.
    ///
    /// **The scene summary no longer reaches the annotation.** See
    /// `usesSceneSynopsis` for the ablation and the costs of the alternatives. This is
    /// the largest of the five and the only one that removes a feature.
    ///
    /// **The word floor scales with the selection.** A flat 90-150 asked a one-line
    /// gloss to reach 90 words, and what filled the gap was invention. `wordBudget`
    /// has the measurement; the band moved out of the instructions and into the
    /// closing line, because it is the one rule whose value depends on the passage.
    ///
    /// **The gloss rule says "early modern English".** The app never said so anywhere,
    /// in any prompt, and it is free. Probed on the raw weights, greedy, no app
    /// context: asked to define `rede` bare, the model answers "a net or mesh for
    /// fishing"; asked to gloss it as an editor's footnote to early modern English, it
    /// answers "a saying, remark, or piece of advice", which is right.
    ///
    /// That probe also drew the ceiling, and it is narrower than it looked. The
    /// predictor is not whether a word is dead — `sith` and `wot` are dead and come
    /// back correct — but whether a **common modern homograph competes** with the
    /// archaic sense. `rede`, `sith` and `wot` have none and are winnable here.
    /// `kind` and `ungracious` have one and lose to it under every neutral framing
    /// tried; those two are a genuine 4-bit ceiling and no prompt reaches them.
    ///
    /// **The out-of-selection rule is scoped to images, not just glossed words.** It
    /// only ever constrained words, so Laertes's canker-and-buds figure from thirteen
    /// lines above the selection walked through it and came back as Ophelia's "a rose
    /// that blooms too soon". An image is not a glossed word; the unit was wrong.
    ///
    /// **Sampling is back at Qwen3's 0.7**, reverting version 8. See `recommended`:
    /// the artifact that justified cooling reproduces at greedy, so it was never
    /// sampling, and cooling cost fluency-without-hedging on a model whose wrong
    /// glosses badly need to look uncertain.
    ///
    /// 11: the early modern frame from 10 is **reverted**, and the reason is worth
    /// more than the revert. It did not add knowledge; it added the register of
    /// knowledge. Every error up to 10 was a false statement about real text. Under
    /// the frame the model began manufacturing text: a spelling variant with its own
    /// quotation marks (`"Reade" is a variant of "rede"`), a provenance for the
    /// primrose path as "a term from Renaissance poetry" when the line in front of it
    /// is the coinage, and a line of verse quoted to the reader in a follow-up row —
    /// `ye soft-voiced, weak-tempered, fleshy-limbed` — which returns zero hits for
    /// `soft-voiced`, `fleshy` or `weak-temper` across all 36 files in
    /// `Resources/Plays`. A reader who searches the page for a real out-of-scope word
    /// is confused; a reader who searches for that finds nothing and concludes the
    /// app is broken, or does not search and believes it.
    ///
    /// The tell is the variance, not the wrongness. Three builds have given three
    /// confident and unrelated meanings for `rede`: "consequences", "a 16th-century
    /// word for consequence or result", "fate or destiny". A knowledge gap gives a
    /// stable wrong answer or a hedge; three uncorrelated confident answers to one
    /// question is generation. Note that this does not overturn the probe behind 10 —
    /// cueing *one* named word as an editor's gloss did recover `rede`. A standing
    /// instruction over every word of every passage is a different intervention, and
    /// at that scale it licenses invention instead of prompting retrieval.
    ///
    /// In its place: say the plain drift and stop when the sense is not known, and an
    /// outright ban on the four surfaces that exist only to be fabricated — century,
    /// etymology, spelling variant, literary source. A gloss is `word (meaning)`.
    /// Quotation is pinned to the page too: nothing in quotation marks that is not
    /// printed in the selected passage, and no line of verse written out at all.
    ///
    /// The same ban now sits on **both follow-up turns**, which carried no version of
    /// any of it and are where the invented verse appeared, and on the answer turn.
    /// `moreFollowUpsRequest` said "in the same style", which by then referred to
    /// rules eight turns back in the transcript and constrained nothing.
    ///
    /// `answerRequest`'s own version-8 clause — "if it asks for two senses of a word,
    /// give two distinct ones" — was a defect I introduced. A reader's question
    /// presupposes its answer, and telling the model to supply two senses when it
    /// holds one is telling it to invent the second. It now has to say which half it
    /// is sure of.
    ///
    /// Also restated: names in prose are ordinary words. `OPHELIA warns…` is
    /// `render()`'s speaker heading bleeding through, note 5's failure returning
    /// because removing the summary in 10 moved the prompt's centre of gravity onto
    /// the labelled blocks.
    ///
    /// Kept from 10, on the expert's reading: the summary stays out (three recurring
    /// invented plot events gone, and not one invented event across four artefacts,
    /// against five before), and the scaled word budget stays (a one-line selection
    /// overshot 70 by nine words, where the flat floor had padded the same line to
    /// 110).
    ///
    /// 12: the misread-phrase class. Where a line has become a common saying, the
    /// saying can outvote the line. Probed on the raw weights, greedy, no app: `the
    /// lady doth protest too much` came back as Ophelia denying guilt — the modern
    /// courtroom sense, and the wrong character, since it is the Player Queen and her
    /// extravagant vows. `to the manner born` came back as "acting in accordance with
    /// his true nature". Both fluent, neither hedged.
    ///
    /// The predictor is not how common the misreading is but **whether the correction
    /// is itself a popular talking point**. "Wherefore means why, not where" is one of
    /// the most repeated teaching points in English and the model gets it right;
    /// `more honour'd in the breach` is a standing usage-column topic and it gets that
    /// right too. The Player Queen's vows have no such champion and it fails.
    ///
    /// Worth the tokens now rather than later, because this class does not stay in
    /// its lane: the `protest too much` answer invented Ophelia into a speech she does
    /// not make. A lexical failure towing a plot fabrication behind it, which is the
    /// population version 10 got to zero by dropping the summary.
    ///
    /// Deliberately **not** the version-10 frame again. That was a standing claim
    /// about every word in the language and it licensed invention. This is a caution
    /// about a phrase the passage actually prints, and it ends the way the gloss rule
    /// ends — say what the lines show and stop — rather than inviting a replacement
    /// meaning to be supplied.
    ///
    /// 13: the gloss budget read as a quota to be spent, so on a passage with nothing
    /// hard in it the model went shopping in the BEFORE window. Hamlet I.iv.16-18 is
    /// three lines of abstract argument next to a run-up full of showy nouns —
    /// wassail, Rhenish, kettle-drum — and the annotation glossed `rhenish`, skipping
    /// all three in-selection candidates. The follow-up lists were worse: three of
    /// four in the first and four of four in the second were about words outside the
    /// selection, and not one about the selected lines.
    ///
    /// Not a capability limit. The same model glossed `honour'd`, `breach` and
    /// `observance` correctly twenty seconds later, when a tapped question pointed it
    /// at them. It can read these lines; it will not choose them unprompted, which
    /// predicts the leak is worst on exactly the abstract passages that most need a
    /// good note.
    ///
    /// The fix is that zero is a permitted answer. "One to three" is a floor and the
    /// only way to meet a floor on a passage with no hard word is to leave the
    /// passage. `followUpRequest` had the same defect and probably the larger share of
    /// it: "one about a word or image" *mandated* a word question, so the prompt was
    /// requiring the behaviour the annotator's rule forbade one turn earlier.
    ///
    /// 14: the yes/no is uncorrelated with the reading that follows it. Asked whether
    /// `more honour'd in the breach` means the custom is broken more often than kept
    /// — which is the popular misreading — the app said "Yes." and then gave the
    /// correct honour reading in the next sentence. Asked the inverse, whether it
    /// means it is more honourable to break the custom than keep it — which is what
    /// the line means — it said it "does not mean" that, and then restated it as its
    /// own reading. Wrong in both directions, with a correct explanation attached both
    /// times.
    ///
    /// So it is not agreement with the questioner: it disagreed once and agreed once,
    /// and both were wrong. The verdict token is simply emitted before the reasoning
    /// that the rest of the sentence contains. The fix is therefore ordering, not
    /// instruction about care: the reading has to be written first, so there is a
    /// committed claim for the verdict to be checked against, and the rule says
    /// outright which one wins when they disagree.
    ///
    /// Severity is why this outranked the model work. Everything before it handed the
    /// reader something wrong; this certifies something wrong that the reader already
    /// believed, at the exact moment they doubted their own reading and asked. Strip
    /// the leading "Yes." from that artefact and it passes — the three glosses under
    /// it were correct and in-selection, the first time the app had managed that.
    ///
    /// Also 14: the gloss rule is now a **positive definition** rather than a list of
    /// bans, which is the third time an enumerated ban has been stepped around. The
    /// bans on century, etymology, variant and provenance held their own content and
    /// left the sentence frame standing over the hole, which then filled with
    /// circularity: `"manner" here is a 16th-century spelling of "manner"`. A gloss is
    /// now defined by what it is — the word, and a meaning that could be substituted
    /// into the line, and nothing else about the word — which is the general form the
    /// four bans were each approximating, and it rules out restating the word as its
    /// own meaning, which no ban had thought to cover.
    ///
    /// One correction to note 12 while it is in view: `to the manner born` came back
    /// **correct** when a reader asked it directly. The class C hazard is real but
    /// that phrase was not an instance of it — the annotation skipped the phrase
    /// because of the shopping problem note 13 fixes, not because the model lacks it.
    ///
    /// 15: the polarity rule from 14 was the visible corner of a larger defect, and it
    /// is generalised here rather than kept beside it. Four artefacts over two rounds
    /// each carry the correct proposition **and** an incompatible one, in the same
    /// short text:
    ///
    /// - "more respected when broken than when followed" / "Yes" to the opposite.
    /// - "more respected when it's broken" / "does not mean it's more honourable to
    ///   break".
    /// - "The ghost insists they swear" / "a boundary that the ghost tries to break".
    /// - "heard through the stage's boards" / "murmuring under the curtain".
    ///
    /// In all four the knowledge is present *in the artefact itself*, so nothing is
    /// missing but a pass over the output. The control is what identifies it: a bare
    /// "what does this word mean" — one proposition, the most constrained output of
    /// the run — came back clean. The contradiction rate scales with how much the app
    /// asks for at once, which is why it shows in annotations and answers and not in
    /// word questions.
    ///
    /// Which half to keep is the empirical part: in every instance the worked-out
    /// reading was right and the verdict or the closing flourish was wrong. So the
    /// rule names that asymmetry instead of saying "be consistent", and it is on both
    /// the annotator and the answer turn, because two of the four were annotations.
    ///
    /// 16: `THE MOMENT`'s direction clause was looking in two places when it should
    /// have been looking at the passage. `PassageContext.manner` inspected
    /// `range.lowerBound` and the line above it and nothing else, which found the
    /// `[_Aside._]` in I.ii — the parser's leading-direction split puts it one line
    /// above the verse it governs — and could not see `[_Cries under the stage._]` or
    /// `[_Beneath._]`, both of which sit in the *middle* of the swearing passage in
    /// I.v. The Ghost's location was on the page three times and the annotation put
    /// him behind a curtain. That looked like the model ignoring the text; it was a
    /// mechanism never pointing at it. The whole selection is scanned now.
    ///
    /// The clause also stops interpreting. It used to append "said apart, not to the
    /// others present", which is true of `[_Aside._]`, false of `[_Beneath._]`, and
    /// would be false again for whichever direction the other 34 plays produce next.
    /// `THE MOMENT` earns its keep by being facts — note 8 — and this was the one
    /// clause that had drifted into reading them aloud.
    ///
    /// Two directions are named and any others are counted. The block works because
    /// it is short enough to read, and a long passage with four directions would make
    /// it longer than the annotation it exists to inform; past two, a count points at
    /// the rest without reproducing them, and they are inline in the passage anyway.
    /// Movement stays filtered, so a scene of entrances announces none of them.
    ///
    /// 17: three ordering-and-prohibition rules have now each produced compliance with
    /// the letter and a fresh expression of the same behaviour — the provenance ban
    /// gave `"rede" is a misspelling of "rede"`, the out-of-window quotation ban gave
    /// out-of-window *paraphrase*, and the opening-verdict ban gave a closing
    /// *inversion*. Four instances. Prohibitions and orderings are cheap for this
    /// model to satisfy without changing what it is doing, so this version stops
    /// writing them.
    ///
    /// What replaces them is a **positive grounding requirement**, which has not been
    /// tried and has a property none of the others had: compliance can be checked
    /// against the selection mechanically, because a claim that names its evidence
    /// either names something on the page or does not.
    ///
    /// Two diseases, and neither is the coherence note 15 addressed:
    ///
    /// **Term drift.** Q3's answer glossed `breach` correctly as "the act of breaking
    /// a rule", let it slide to "disrespect" two sentences on, and then re-derived
    /// from the looser sense into the inverse of its own opening claim. Every sentence
    /// is locally consistent with what the word meant at that moment, so note 15's
    /// check has nothing to fire on — two incompatible claims are never live under one
    /// reading. The fix is term stability: a glossed word keeps its meaning, and a
    /// sentence needing a different one is the wrong sentence.
    ///
    /// **Ungroundedness.** Q4 is not incoherent about the text, it never touches it.
    /// `[Beneath.]` twice inside the selection, "cellarage" at 167, "Canst work i'
    /// th' earth so fast" at 179 — none used, a curtain invented instead. Note 15 had
    /// nothing to grip here either: Q3's question supplies a proposition to test,
    /// Q4's is open, so the model must generate the claim *and* audit it. The fix is
    /// to require that a claim about position or staging point at the words showing
    /// it, or say plainly that none do.
    ///
    /// Note 16 surfaced those directions and the annotation still did not use them, so
    /// surfacing was necessary and not sufficient. It also cost something: v12 had one
    /// correct sentence about the Ghost's voice through the boards and glossed
    /// `truepenny`, and v16 dropped both. Recorded because it is the first measured
    /// regression from a change of mine that was otherwise right.
    ///
    /// Also 17: the in-selection rule holds in `annotatorInstructions` — the
    /// annotation's own leak has been clean for two consecutive items — and does not
    /// hold in `followUpRequest`, where Q3 produced three of four rows from outside
    /// the selection. Rather than state it a third time, the quota is relaxed. "Output
    /// exactly four" is the same shape as the gloss floor note 13 removed: on a
    /// passage with three good questions in it, the only way to produce a fourth is to
    /// leave the passage. Three is now allowed and said to be better. If the leak
    /// survives that, the quota was not the cause and the rule needs a different
    /// instrument.
    ///
    /// 18: three repairs, one of which is a rule that had been scored against for
    /// three versions without being in the prompt.
    ///
    /// `answerRequest` used to end "If the play does not settle it, say so." Version
    /// 14 rewrote that whole string to fix the two-senses defect and dropped the
    /// clause in the same edit, unnoticed. It is restored — **alongside** "where you
    /// are not sure, say which part" rather than instead of it, because they are
    /// different predicates and both are wanted. One is a claim about the text: this
    /// crux is contested. The other is a claim about the speaker's confidence. They
    /// come apart exactly at the nunnery scene, where the scholarship is divided and
    /// the model's reading was judged defensible — so a confidence clause cannot fire
    /// on a textual crux however it is worded.
    ///
    /// If it stays inert after restoration, the reason is a knowledge precondition
    /// rather than a phrasing one: the grounding rule names a target the model has to
    /// produce, while this one needs it to already know that editors disagree, and
    /// nothing in the prompt tells it. That would be a finding, not a failed rule.
    ///
    /// The paragraph count joins the word budget in `closing()`. See `wordBudget` for
    /// why that is more interesting than the fix.
    ///
    /// Grounding extends from position to attributed diction: if the annotation says
    /// a speaker calls someone something, that word has to be printed. Q6's answer
    /// invented "he does call her a tempter", which the version 17 rule missed because
    /// it was scoped to where people are and what they physically do. Deliberately not
    /// widened to "any claim" — that is the shape that flattens.
    ///
    /// 19: the answer turn gets a **revision pass**, which is the first structural
    /// change of the run rather than another rule. See `answerRevision` for the
    /// mechanism and `QuoteCheck` for the free half of it.
    ///
    /// Native thinking was measured first and rejected. Flipping `enable_thinking`
    /// mid-session is free in prefix terms — in Qwen3's template the flag appears only
    /// inside `{%- if add_generation_prompt %}`, so it cannot alter a single earlier
    /// token, and no re-prefill is forced. That also settles the turn-2 mystery the
    /// README records: with thinking off the template injects `<think>\\n\\n</think>`
    /// into the generation prompt, those tokens enter the cache, and the next turn
    /// re-renders the stored assistant content without them. But on the Q7 passage
    /// question, thinking on ran **1,217 tokens and 7.9 s** against roughly a second
    /// now, and produced a *worse* answer than thinking off: still Ophelia rather than
    /// the Player Queen, plus "the Queen's daughter" and Polonius's death, which has
    /// not happened at III.ii. Eight times the latency for two new errors.
    ///
    /// Answers only, and that is a product decision rather than a technical one: a
    /// reader who has just clicked a line has nothing on screen to wait against, while
    /// a reader who has tapped a question has the annotation in front of them. The
    /// annotation keeps its 0.74 s and keeps streaming.
    ///
    /// Also 19: `WHO THEY ARE` stops dropping speakers the cast list does not
    /// describe. `PassageContext.build` has the Hamlet III.ii evidence; the short
    /// version is that the block named three courtiers and omitted the Player Queen,
    /// who is the referent of "the lady", while the on-stage scan had removed her two
    /// lines earlier and left Ophelia standing. The context deleted the right answer
    /// and supplied the wrong one.
    ///
    /// 20: the on-stage list was asserting a false fact, and had been doing so for
    /// every passage after a joint speech heading. `OnStageTracker.members(of:cast:)`
    /// carries the mechanism. What it cost: Hamlet III.iii ends with Claudius alone,
    /// and the prompt read `On stage, approximately: King and Rosencrantz And
    /// Guildenstern`. Five of eight annotations sampled at the shipping temperature
    /// duly had him speaking to them — "The king speaks to Rosencrantz and
    /// Guildenstern", "The courtiers watch", "The others listen".
    ///
    /// Both the engineer and the expert had booked that as the model importing from
    /// its weights, and a theory of thin-context confabulation was built on it. Half
    /// of that moves back into the app's column. What survives: the *other*
    /// fabrication in the same item, a dying Polonius, has no in-prompt source and
    /// **did not survive greedy decoding**, so it is sampling-sensitive rather than a
    /// ceiling. And removing the word figure entirely made the output *longer* and
    /// still fabricated, so the floor was never the whole story either.
    ///
    /// The mangled `Rosencrantz And Guildenstern` in the rendered list was the visible
    /// marker of this and was passed over as cosmetic several versions earlier. It was
    /// not cosmetic. The string was *rendered into the prompt*, and malformed output
    /// on data the model reads is a symptom rather than a blemish.
    ///
    /// Scope: 24 joint headings across 15 of the 35 plays, 11 in Hamlet. Exposure runs
    /// from the heading to the end of the scene, because `OnStageTracker.onStage` scans
    /// scene start to selection — **not** the context window, which is a much shorter
    /// span and is the wrong thing to reason with. Of the graded passages, five sit
    /// after a joint heading in their scene and four do not.
    ///
    /// That partially confounds the reading that short selections fabricate, and does
    /// not replace it: one item fabricated with no phantom present, and another did
    /// not fabricate with one. Both effects are real, neither is established, and the
    /// five overlapping items cannot separate them. Re-running the exposed passages on
    /// this version is what would.
    ///
    /// Also 20: version 19's bare-name roster rows are **taken back out**, measured
    /// inert — see `PassageContext.build`. The third fact `WHO THEY ARE` has been
    /// handed that changed nothing.
    ///
    /// The capped short-selection promise trialled alongside this is **not shipped**.
    /// It won its first comparison only because the arm it beat was using the phantom;
    /// on a prompt with the bug fixed the current budget wins, and the capped form
    /// transcribes the passage in half its samples while carrying the anti-
    /// transcription clause verbatim. Removing the word figure altogether was worse
    /// still: the output got *longer* and fabricated, which is worth knowing before
    /// anyone tries it again.
    static let version = 20

    // MARK: - Annotation

    static let annotatorInstructions = """
        You are a Shakespeare annotator writing in the style of a Genius.com \
        annotation: short, concrete, plain modern English. No hedging, no lecturing, \
        no summary of what you were given.

        You get one selected passage plus the scene around it. Explain ONLY the \
        selected passage. The rest is there so your explanation fits the moment.

        Rules:
        - No headings, no bullets, no preamble. The length and the shape are set at \
        the end.
        - First sentence: what the passage says, in plain modern English.
        - Then: why it matters here. What the speaker wants, what just changed, who is \
        listening, what they do not know.
        - Gloss the words a reader today would actually miss. Up to three, and often \
        none — many passages are plain argument with nothing hard in them, and \
        glossing nothing is the right answer there. Never go outside the passage to \
        find a word worth glossing.
        - A gloss has one shape and no other: "word" (what it means here), inline in \
        the sentence that needs it, never a list at the end. The parenthesis holds a \
        modern synonym, or a short phrase a reader could substitute into the line, and \
        nothing else about the word at all — and never the word itself again. If you \
        cannot give a meaning that could be substituted in, do not gloss it: give the \
        plain drift of the lines and leave the word alone.
        - Every word, image and comparison you discuss must come from the selected \
        passage. Check that before you write it: if it is only in the lines around the \
        passage it is out of bounds, however apt it looks. Quote at most six words at \
        a time, say what the lines mean before you quote any of them, and put nothing \
        in quotation marks that you cannot see on the page — never a line of verse \
        that is not printed in front of you.
        - A phrase that has become a common saying often does not mean here what it \
        means now. Check it against these lines; if they do not settle it, say what \
        they do show and leave the saying alone.
        - Write names as ordinary words: Ophelia, not OPHELIA. The capitalised \
        headings belong to the transcript, not to your sentences.
        - Use only what you were given, and keep the speech situation straight: do \
        not add people the lines do not put there, someone who has not entered is not \
        watching, and words belong to whoever the passage gives them to — a speech to \
        one person is not aimed at another. If the passage turns on something you were \
        not given, say so in one clause instead of inventing it.
        - Never mention the context, act or scene numbers, or these instructions. Do \
        not begin with "This passage" or "Here".
        - Hold one reading to the end. Before each sentence, check it against what you \
        have already written: if two claims cannot both be true, keep the one the \
        lines support and cut the other. A closing line that contradicts the \
        explanation above it is the closing line's mistake, not the explanation's.
        - Say where someone is, or what they are physically doing, only from words on \
        the page: point at the stage direction or the phrase that shows it. If nothing \
        in the passage shows it, leave it out rather than picturing it. Same for what \
        a speaker calls someone: if you write that he calls her a name, that name is \
        printed in the passage or you do not write it.
        - A word you gloss keeps that meaning for the rest of what you write. If a \
        later sentence needs a looser or different sense of it, that sentence is \
        wrong, not the gloss.
        - Present tense. No moral at the end.
        """

    /// The passage and its surroundings, in labelled blocks.
    ///
    /// Ordered **scene-invariant sections first**, then the passage window. That
    /// ordering is what would make a per-scene prefix cache possible later
    /// (`ChatSession(cache:state:)`) without rewriting the prompts.
    static func annotationRequest(_ context: PassageContext) -> String {
        var blocks: [String] = []

        blocks.append("PLAY: \(context.playTitle) by \(context.author)")
        blocks.append(
            "LOCATION: Act \(RomanNumeral.string(context.act)), "
                + SceneLabel.string(context.scene))
        if let setting = context.setting {
            blocks.append("SETTING: \(setting)")
        }
        if let opening = context.openingDirection {
            blocks.append("SCENE OPENS: \(opening)")
        }
        if !context.personae.isEmpty {
            let notes = context.personae.map { "- \($0.display): \($0.blurb)" }
            blocks.append((["WHO THEY ARE:"] + notes).joined(separator: "\n"))
        }
        if let synopsis = context.synopsis, usesSceneSynopsis {
            let label =
                context.synopsisIsPartial
                ? "SCENE SUMMARY (rough, and only the first part of the scene):"
                : "SCENE SUMMARY (rough, runs to the end of the scene; the lines "
                    + "below are the authority):"
            blocks.append("\(label)\n\(synopsis)")
        }

        if !context.preceding.isEmpty {
            blocks.append(
                "BEFORE\(lineSpan(context.preceding)):\n\(render(context.preceding))")
        }
        blocks.append(
            "SELECTED PASSAGE\(lineSpan(context.selected)):\n\(render(context.selected))")
        if !context.following.isEmpty {
            blocks.append(
                "AFTER\(lineSpan(context.following)):\n\(render(context.following))")
        }

        if let moment = moment(context) {
            blocks.append(moment)
        }
        blocks.append(closing(context))
        return blocks.joined(separator: "\n\n")
    }

    /// Who is speaking, to whom, in front of whom, and how far into the scene —
    /// stated once, in facts, at the end.
    ///
    /// This is the answer to the failure that arrived in four costumes across two
    /// graded passages: Claudius's line given to Hamlet; an aside answered as though
    /// spoken to the man's face; Ophelia's speech to her brother read as a warning to
    /// an absent Hamlet; Polonius described as watching a scene he enters two lines
    /// after. Every one of those facts was already in the request and correct — the
    /// I.iii `ON STAGE` block read exactly `Laertes, Ophelia` — and the model still
    /// lost them.
    ///
    /// What they have in common is *position*. A fact that holds later in the scene
    /// beat a fact that holds now, because the later one sat nearer the end of the
    /// prompt: `[Enter Polonius.]` in the AFTER block, Hamlet's name in five of the
    /// summary's six sentences. So the present situation is restated last, where the
    /// competing material was winning from, and the not-yet is said out loud rather
    /// than left to be inferred from a block label.
    ///
    /// Deliberately **facts and not a rule**. A rule strong enough to bind the speech
    /// situation is exactly the kind that flattens every gloss it touches; a
    /// four-clause statement of who is in the room cannot, because there is no
    /// register in it to leak. The one imperative is the last clause, and it forbids
    /// an error rather than prescribing a shape.
    ///
    /// `ON STAGE` moved here from the head of the request, so it is not duplicated.
    /// That is also a small repair to the ordering the doc comment above claims:
    /// `onStage` is computed `upTo:` the selection, so it was never scene-invariant
    /// and never belonged in the prefix.
    private static func moment(_ context: PassageContext) -> String? {
        var sentences: [String] = []

        if !context.speakers.isEmpty {
            var who = "\(list(context.speakers)) "
                + (context.speakers.count == 1 ? "speaks" : "speak") + " these lines"
            let numbers = context.selected.compactMap(\.number)
            if let first = numbers.first, let last = numbers.last, context.sceneLineCount > 0 {
                let span = first == last ? "line \(first)" : "lines \(first)-\(last)"
                who += ", \(span) of the scene's \(context.sceneLineCount)"
            }
            sentences.append(who + ".")
        }

        // Stated and not read. `[_Aside._]` used to carry "said apart, not to the
        // others present", which was true of that one direction and would be wrong
        // of `[_Beneath._]` — and wrong again for whatever the other 34 plays hold.
        // THE MOMENT earns its keep by being facts; this clause was the one place it
        // drifted into interpretation, and `[Aside.]` is not a term the model needs
        // glossed anyway.
        //
        // Two, then a count. The block is worth reading because it is short, and a
        // fifteen-line passage with four directions would make it longer than the
        // annotation it is supposed to inform. Past two, naming the number points at
        // the rest without reproducing them — they are already inline in the passage,
        // which is where a reader of the block will go looking.
        if !context.stageDirections.isEmpty {
            let shown = context.stageDirections.prefix(2).map { "[\($0)]" }
            let rest = context.stageDirections.count - shown.count
            sentences.append(
                "Marked \(list(shown))"
                    + (rest > 0 ? ", and \(rest) more stage direction\(rest == 1 ? "" : "s")" : "")
                    + ".")
        }
        if !context.onStage.isEmpty {
            // Still labelled approximate, because it still is: the scan reads Enter
            // and Exit directions, which are written for actors, not parsers.
            //
            // It binds against adding bodies without asserting there are none. See
            // note 9: the scan cannot see a concealed listener, and III.i is a scene
            // built on one.
            sentences.append(
                "On stage, approximately: \(list(context.onStage)) — everyone the "
                    + "directions record. Do not add anyone the lines do not.")
        }

        if let last = context.selected.compactMap(\.number).last {
            sentences.append(
                "Nothing after line \(last) has happened yet, so do not write as if it had.")
        }

        guard !sentences.isEmpty else { return nil }
        return "THE MOMENT: " + sentences.joined(separator: " ")
    }

    /// `A`, `A and B`, `A, B and C`. Worth the few lines because this text is read
    /// closely by the model and a trailing comma reads as a fourth person.
    private static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Whether the scene summary reaches the annotation prompt at all.
    ///
    /// **Off, on measurement.** `--benchmark` builds its context without a synopsis
    /// and never prewarms one, so it is already the ablation: the same two graded
    /// passages, greedy, with and without. Without it, Hamlet I.ii.66 loses the Ghost
    /// and the complicit Queen outright and reads Claudius as "his uncle … and his
    /// stepfather" instead of "more than a brother"; I.iii.48-54 loses Polonius
    /// watching a scene he has not entered, loses Laertes's canker-and-buds image
    /// re-attributed to Ophelia, and gets the pastor simile the right way round. What
    /// it costs is nothing anyone could point to.
    ///
    /// Two cheaper fixes were tried first and neither bound. Version 8 added
    /// `THE MOMENT`, which says in words that nothing after the selected line has
    /// happened yet, and relabelled the block "rough … the lines below are the
    /// authority". The Ghost came through both.
    ///
    /// The accuracy underneath is the reason to stop rather than to tune: the I.ii
    /// summary has been generated twice and been wrong both times, differently — once
    /// putting the Ghost's revelation in I.ii, once marrying Claudius to Ophelia. A 4B
    /// model compressing 284 lines into 90 words is the limit, and the README's
    /// promise of "a summary of the scene *so far*" was never what `synopsisRequest`
    /// built: it summarizes the whole scene, which is exactly the property that
    /// back-dates I.v into I.ii.
    ///
    /// Genuinely "so far" is the obvious repair and it is the one that cannot be
    /// afforded: the boundary moves with every selection, so the per-scene cache key
    /// stops working and there is nothing to prewarm, and each selection pays a fresh
    /// 10-20 s summary before its annotation starts — against a measured 0.74 s to
    /// first token, with arrow-key re-glossing the interaction that dies for it.
    ///
    /// The design that would work is beats tagged with line ranges: one generation per
    /// scene, so prewarm and cache both survive, and the prompt includes only the
    /// beats ending at or before the selection. It is not built here because it asks
    /// the component that already cannot summarise the scene to also emit reliable
    /// line numbers, and because it would not have saved I.ii — filtering hides a
    /// fabricated *late* beat, and does nothing about a fabricated early one.
    ///
    /// A flag rather than a deletion because the summary has ~90 references across
    /// nine files, because this is one measurement on one scene, and because flipping
    /// it back is how the next A/B gets run. It is not a permanent home: either the
    /// beats get built or the machinery comes out.
    static let usesSceneSynopsis = false

    /// How many words the annotation gets, and in how many paragraphs, by how much
    /// was selected.
    ///
    /// Was a flat 90-150 in the instructions, which is a footnote's length whatever
    /// the reader clicked. Measured at version 9 over the 13 sample passages: mean 147
    /// words, and 7 of 13 over the ceiling — the band was not holding at the top, and
    /// at the bottom it was doing something worse. A one-line selection still had to
    /// reach 90 words, and what fills the gap is invention: "The tension is high",
    /// "The others don't get it", "she's in a position to shape Laertes' understanding
    /// of love and danger". The floor was buying padding and the padding was wrong.
    ///
    /// So the floor scales. A good footnote on one line is thirty or forty words, and
    /// the model is now allowed to stop there.
    ///
    /// The paragraph count joined it in version 18, and why is the interesting part.
    /// "Two or three short paragraphs" sat in the instructions while the word count
    /// moved here in version 11 — the same decision, split across two places. The word
    /// count has been obeyed since it moved; the paragraph count was violated on four
    /// consecutive graded items. Part of that is arithmetic, since three paragraphs
    /// inside a 35-70 word budget is not a paragraph, but two of the four had room and
    /// did it anyway. The rest is placement, which is the one thing the prompt has run
    /// a controlled experiment on by accident: same information, two locations, and
    /// only the one at the end binds. Worth remembering for the next rule that will
    /// not stick.
    static func wordBudget(lines: Int) -> (low: Int, high: Int, paragraphs: Int) {
        switch lines {
        case ..<3: (35, 70, 1)
        case ..<10: (60, 110, 2)
        default: (90, 150, 2)
        }
    }

    /// Where a selection stops being one the word budget was tuned on.
    ///
    /// 30 speech lines, and not lower, because that is where the measured overruns
    /// start. Of the 13 sample passages the two longest are the two that break the
    /// budget — III.i.62-96 at 35 lines wrote 176 words and I.v.48-96 at 49 lines
    /// wrote 208 — while Macbeth I.vii.1-28, at 28, wrote 124 and needs nothing. A
    /// threshold that also caught the Macbeth would be spending prefill, and
    /// flattening a gloss, on a passage that already meets the rule.
    static let longSelection = 30

    /// The request's last line: the last thing the model reads before it writes.
    ///
    /// The instructions are 500-1,000 tokens back by then, and everything between
    /// them and here is verse — so the rules the model was seen to drop wholesale sit
    /// here rather than there. The word budget is here for the same reason and for
    /// one more: it is the only rule whose value depends on the passage, so stating
    /// it in the instructions meant stating it wrong for every selection but one.
    /// The long-selection half is emitted only when it applies, so a four-line
    /// passage pays nothing for it.
    private static func closing(_ context: PassageContext) -> String {
        // `filter` rather than `count(where:)`: that one is gated on the Swift 6
        // standard library, and this app deploys to macOS 14.
        let lines = context.selected.filter { !$0.isDirection }.count
        let budget = wordBudget(lines: lines)

        var text =
            "Annotate the selected passage in \(budget.low)-\(budget.high) words, "
            + (budget.paragraphs == 1 ? "in one paragraph. " : "in two short paragraphs. ")
            + "Your first sentence has to be your own words, not the passage's: do "
            + "not open with a speaker heading or with the lines themselves, and do "
            + "not carry a capitalised heading into your prose — write Ophelia, not "
            + "OPHELIA. Stop when you have said what the lines mean and why they "
            + "matter — do not pad to the upper figure."

        if lines >= longSelection {
            text +=
                " It runs to \(lines) lines, and still gets one annotation of that "
                + "length: what the whole passage does, and where it turns. Do not "
                + "walk it line by line, and do not let one vivid image from the "
                + "middle stand in for the rest."
        }
        return text
    }

    /// Groups consecutive lines by the same speaker under one heading. Repeating
    /// `HAMLET.` on every line costs about three tokens each for no information.
    static func render(_ utterances: [PassageContext.Utterance]) -> String {
        var out: [String] = []
        var current: String?
        for utterance in utterances {
            if utterance.isDirection {
                out.append("[\(utterance.text)]")
                // A direction between two runs of the same speaker does not
                // re-open the heading, because the speech continues through it.
                continue
            }
            if let speaker = utterance.speaker, speaker != current {
                out.append("\(speaker):")
                current = speaker
            }
            out.append("  \(utterance.text)")
        }
        return out.joined(separator: "\n")
    }

    private static func lineSpan(_ utterances: [PassageContext.Utterance]) -> String {
        let numbers = utterances.compactMap(\.number)
        guard let first = numbers.first, let last = numbers.last else { return "" }
        return first == last ? " (line \(first))" : " (lines \(first)-\(last))"
    }

    // MARK: - Follow-ups

    /// The follow-up turn carries its own copy of the no-invention rules.
    ///
    /// It used to carry none of them, and it is where the worst single output of the
    /// quiz appeared: a row quoting `ye soft-voiced, weak-tempered, fleshy-limbed`,
    /// which is in no play in `Resources/Plays` and is not Shakespeare. The
    /// annotator's rules do not reach here — this is a separate turn with its own
    /// instructions — so a reader tapping a question was being offered fabricated
    /// verse by the one surface that had no rule against it.
    static let followUpRequest = """
        Now propose up to four follow-up questions a curious reader would tap next \
        about this same passage.

        Rules:
        - Each one must be specific to this passage: name the person, image, or word \
        it is about. Before you write a question, check that every word you put in \
        quotation marks is printed in the selected passage. If it is only in the \
        lines around it, drop the question and write a different one.
        - Never invent. No line of verse you cannot see, no spelling variant, no \
        century, no source. Ask about what is on the page.
        - Four to nine words each. Do not ask anything you just answered.
        - Vary them: motive, what changes, staging, tone — and a word or image only \
        if the passage has one worth asking about. A passage of plain argument may \
        have none, and four questions about the argument is the right answer there.
        - Output three or four numbered lines and nothing else. Three the passage can \
        answer are better than four where the fourth is about something it does not \
        contain.
        """

    /// Sent once when the first attempt yielded fewer than two usable questions.
    /// Phrased as something a person could plausibly say, because it stays in the
    /// transcript the model sees on every later turn.
    static let followUpRetry =
        "Try again: output exactly four numbered lines and nothing else."

    /// A tapped question, plus how to answer it.
    ///
    /// The "two distinct senses" clause added in version 8 was a defect of its own
    /// making. A reader's question often presupposes an answer — *what are the two
    /// senses of "kind"* — and an instruction to supply two when the model holds one
    /// is an instruction to manufacture the second, which is exactly what it did.
    /// Answering every part of what was asked has to include being able to say that
    /// part of it cannot be answered.
    ///
    /// The reading-before-verdict rule is version 14's, and it is the same fault one
    /// level up: a sentence frame emitted before the content that should decide it.
    /// See note 14.
    static func answerRequest(_ question: String) -> String {
        """
        \(question)

        Answer in 60-110 words, plain modern English, same voice as before.

        If the question asks whether something is so, do not open with Yes or No. Say \
        what the lines actually mean first, in your own words, and only then say \
        whether that is what the question described.

        Hold one reading to the end. Before each sentence, check it against what you \
        have already written: if two claims cannot both be true, the worked-out \
        reading is the one to keep and the verdict or the closing line is what \
        changes. Never ship both.

        Any claim about where someone is, or what they are doing physically, must \
        point at the words that show it — the stage direction, or the phrase from the \
        lines. If the passage does not show it, say so. If you write that a speaker \
        calls someone something, that word has to be printed in the passage. A word \
        you gloss keeps that meaning for the whole answer; if a later sentence needs \
        a looser sense of it, that sentence is wrong, not the gloss.

        Answer every part of what was asked, and where you are not sure, say which \
        part. If the play itself does not settle the question — if the lines honestly \
        bear more than one reading — say so, and then give the one you find likeliest. \
        If the question assumes something and you are confident of only half of \
        it, give that half and say so rather than filling the shape. A phrase that is \
        now a common saying may not mean here what it means now. A meaning is a modern \
        paraphrase of the word and nothing else about it. Quote nothing you cannot see \
        in the passage. Keep the speech situation as it stands there. Do not repeat \
        your earlier explanation or reuse its phrases.
        """
    }

    /// Sent after the answer draft, on the same session, so the draft is in view.
    ///
    /// The one turn in the app that supplies an **edit channel**. Version 17 told the
    /// model that a glossed word keeps its meaning, and Q7 shows it complying in the
    /// only way a single forward pass allows: `"Protest" here means "object"` … 78
    /// words later … `"Protest" is not "object" — it's "overreact."` It quoted and
    /// negated its own earlier claim, because having read the drift it could not go
    /// back and fix sentence two. It could only continue. The instructions were asking
    /// for revision and the architecture offered continuation.
    ///
    /// So the ordering rules stay, and this gives them somewhere to land. Note the
    /// third bullet: appending a correction is exactly what the model already does
    /// unaided, and it is not what a revision is for.
    ///
    /// Answers only. Annotations keep their 0.74 s and keep streaming — they are the
    /// half that has started passing, and a reader who has just clicked a line has
    /// nothing on screen to wait against, where a reader who has tapped a question has
    /// the annotation in front of them.
    static let answerRevision = """
        Now revise that answer. It is above; this is your one chance to change it.

        - If two sentences contradict each other, delete the wrong one. Do not add a \
        sentence correcting yourself — take the wrong sentence out.
        - Your earlier explanation of this passage is above too. If the answer \
        contradicts it, one of them is wrong: fix the answer to agree with whichever \
        the lines support.
        - If a sentence repeats your earlier explanation of this passage, or reuses \
        its wording, replace it with something the reader does not already have.
        - Keep what was right, keep the length, and add no new claims.
        - Output the revised answer and nothing else. No preamble, no notes on what \
        you changed.
        """

    /// Asks for up to five so four can survive the dedupe against questions already
    /// asked.
    ///
    /// Restates the two rules rather than saying "in the same style". This is the
    /// turn every row after the first answer comes from, and "the same style" was
    /// carrying no constraint at all — the rules it was gesturing at are eight or ten
    /// turns back in a transcript by then.
    static let moreFollowUpsRequest = """
        Suggest up to five more questions about this same passage. Same rules: only \
        words the selected passage itself prints, and nothing invented — no verse you \
        cannot see, no spelling variant, no century, no source. Two the passage can \
        answer are better than five that reach outside it. Do not repeat any question \
        already asked. Output only the numbered lines and nothing else.
        """

    /// A word right-clicked in the verse, as a question.
    ///
    /// Phrased as a reader's own question and nothing more, because that is what it is:
    /// it goes through `ask(_:)` and `answerRequest(_:)`, which already set the length and
    /// the voice, and it is shown verbatim in the transcript as the thing that was asked.
    /// A separate instruction block would be a second voice in a session that already has
    /// one.
    ///
    /// The one string in this file that owes **no `version` bump**. The rule above is
    /// about strings that change cached output, and nothing is cached from this one:
    /// `AnnotationCache` keys on turn 1, which a word question does not touch.
    static func wordQuestion(_ term: String) -> String {
        "What does “\(term)” mean here?"
    }

    /// Turns the model's numbered list into tappable questions.
    ///
    /// Lives beside the prompt that asks for the list, because the two are one
    /// contract: every allowance here exists for a way the model has been seen to
    /// break "output exactly four numbered lines and nothing else."
    enum FollowUps {
        static func parse(_ raw: String, asked: Set<String> = [], limit: Int = 4)
            -> [String]
        {
            // Built per call rather than held in a `static let`: `Regex` is not
            // `Sendable`, and a numbered list is at most a handful of lines.
            // Tolerates a bullet before the number, and `.`, `)`, `]`, `:` or `-`
            // after it.
            let line = /^\s*(?:[-*•]\s*)?(\d{1,2})\s*[.)\]:‑-]\s*(.+?)\s*$/

            var questions: [String] = []
            var seen = asked

            for text in raw.split(whereSeparator: \.isNewline) {
                guard let match = try? line.wholeMatch(in: text) else { continue }

                var question = unwrapped(
                    String(match.2)
                        .replacingOccurrences(of: "**", with: "")
                        .trimmingCharacters(in: .whitespaces))

                // A stray preamble line ("Here are four questions:") never matches
                // the number pattern; these bounds catch the other end, a numbered
                // line that is actually a paragraph.
                guard question.count >= 3, question.count <= 120 else { continue }

                if !question.hasSuffix("?") {
                    // Not every numbered line is a question. Muse-Glimmer answered
                    // the follow-up request with declarative sentences lifted from
                    // its own commentary, and appending a bare "?" produced the row
                    // "It establishes a wary, military tone at the castle gate.?"
                    // Dropping the trailing stop is the easy half; the real fix is
                    // to require the shape of a question rather than to costume a
                    // statement as one.
                    guard looksInterrogative(question) else { continue }
                    while let last = question.last, ".!,;:".contains(last) {
                        question.removeLast()
                    }
                    question += "?"
                }

                let key = normalized(question)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                questions.append(question)
                if questions.count == limit { break }
            }
            return questions
        }

        /// Strips one pair of wrapping quotes, and only a matching pair.
        ///
        /// This was `trimmingCharacters(in: " \t\"“”‘’'")`, which takes from each end
        /// independently and so cannot tell packaging from content. On
        /// `"quintessence of dust" – what does it mean?` it removed the opening quote
        /// and left the closing one stranded mid-row, which is the shape that shipped:
        /// `quintessence of dust" – what does it mean?`. A quote at one end only is
        /// part of the question — and a question that opens by quoting the passage is
        /// exactly what the follow-up prompt asks for, so this was aimed at the rows
        /// most likely to be good ones.
        private static func unwrapped(_ text: String) -> String {
            let pairs: [(Character, Character)] = [
                ("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"),
            ]
            guard text.count >= 2, let first = text.first, let last = text.last,
                pairs.contains(where: { $0.0 == first && $0.1 == last })
            else { return text }
            return text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        }

        /// Dedupe key: case and punctuation are not a difference worth showing the
        /// reader two rows for.
        static func normalized(_ question: String) -> String {
            question.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                .trimmingCharacters(in: .whitespaces)
        }

        /// Whether an item with no question mark still reads as a question.
        ///
        /// Deliberately a whitelist of openings rather than anything cleverer: the
        /// cost of rejecting a real question is one fewer row, and the cost of
        /// accepting a statement is a row that lies about being a question.
        private static let interrogatives: Set<String> = [
            "what", "why", "how", "who", "whom", "whose", "when", "where", "which",
            "is", "are", "was", "were", "does", "do", "did", "can", "could", "should",
            "would", "will", "has", "have", "had", "in", "at",
        ]

        static func looksInterrogative(_ question: String) -> Bool {
            guard
                let first = question.lowercased()
                    .split(whereSeparator: { !$0.isLetter }).first
            else { return false }
            return interrogatives.contains(String(first))
        }
    }

    // MARK: - Synopsis

    /// Its own instructions in its own throwaway session: the annotation session's
    /// KV cache has to begin with a prefix that every follow-up reuses, and
    /// splicing a summarization turn into it would both lengthen that prefix and
    /// ask one session to hold two voices.
    static let synopsisInstructions = """
        You summarize one scene of a play for a reader who is about to read it. One \
        paragraph, 60-90 words, plain modern English. Only what is in the text you \
        are given, in the order it happens: who is present, what they want, what \
        changes. No quotations, no interpretation, no list, no preamble.
        """

    static func synopsisRequest(
        _ scene: Scene, act: Int, number: Int, lineLimit: Int
    ) -> String {
        let lines = scene.lines.prefix(lineLimit)
        let coverage =
            lines.count < scene.lines.count
            ? "SCENE TEXT (lines 1-\(lines.count) of \(scene.lines.count))"
            : "SCENE TEXT"

        let utterances = lines.map {
            PassageContext.Utterance(
                speaker: $0.speaker, number: $0.number,
                text: $0.plainText,
                isDirection: $0.isDirection)
        }

        return """
            Act \(RomanNumeral.string(act)), \(SceneLabel.string(number))\
            \(scene.setting.isEmpty ? "" : " — \(scene.setting)")

            \(coverage):
            \(render(utterances))

            Summarize this scene.
            """
    }

    /// Long scenes are capped rather than chunked. Map-reduce over the handful of
    /// very long scenes (Hamlet II.ii is ~600 lines) is explicitly v2; what matters
    /// now is that the cap is stated in the prompt and surfaced in the UI.
    static let synopsisLineLimit = 300

    /// Drops a trailing fragment from a summary that ran into its token limit.
    ///
    /// The summary is asked for 60-90 words and sometimes writes 110, which used to
    /// arrive cut mid-clause — and then went into the annotation prompt that way. A
    /// summary that stops one sentence early reads as deliberate; one that stops
    /// mid-phrase reads as a bug, to the reader and to the model.
    static func tidySynopsis(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        guard let end = trimmed.lastIndex(where: { ".!?".contains($0) }) else {
            return trimmed
        }
        return String(trimmed[...end])
    }

    // MARK: - Sampling

    /// The four presets, carried as a value rather than as mutable globals so
    /// `--greedy` is a different `SamplingPresets` and not a process-wide mutation
    /// that Swift 6 would rightly complain about.
    struct SamplingPresets: Sendable {
        var commentary: GenerateParameters
        var followUp: GenerateParameters
        var answer: GenerateParameters
        var synopsis: GenerateParameters

        /// Qwen3's own recommendation for non-thinking mode, except the scene summary.
        ///
        /// Version 8 cut `commentary` and `answer` to 0.5 to reduce corrupted tokens
        /// — `opheelia`, a bare `他`, `Opophelia`. **That premise was wrong and this
        /// is the revert.** `Opophelia` reproduces at `--greedy`, temperature 0, seed
        /// 0, so it is the argmax of the 4-bit weights and not something sampling
        /// reaches. Cooling bought nothing against it and cost something real: the
        /// graded output at 0.5 was more fluent and more confidently wrong, inventing
        /// dictionary entries like *rede*, "a 16th-century word for consequence",
        /// which a reader has no way to catch. Hedging tokens are low-probability, so
        /// a colder distribution suppresses exactly the uncertainty a wrong gloss
        /// ought to show.
        ///
        /// **The corrupted token has no fix at 4 bits.** It is a quantization
        /// artifact, it survives greedy decoding, and no sampling or prompt change
        /// available here removes it. Recorded rather than left looking unaddressed:
        /// three in three graded items, always a proper name or a stray CJK
        /// character, and the only lever that would move it is a wider model.
        ///
        /// `synopsis` stays at 0.3 because it is meant to be dull; it is also the
        /// least accurate output the app produces, which is why version 10 stopped
        /// feeding it to the annotation rather than tuning it.
        ///
        /// `maxTokens` is the only field that differs between turns, which matters:
        /// mutating `kvCache`, `maxKVSize`, or `kvBits` on a live session throws
        /// `kvCacheConfigurationChanged`.
        static let recommended = SamplingPresets(
            commentary: GenerateParameters(
                maxTokens: 320, temperature: 0.7, topP: 0.8, topK: 20),
            followUp: GenerateParameters(
                maxTokens: 140, temperature: 0.7, topP: 0.8, topK: 20),
            answer: GenerateParameters(
                maxTokens: 260, temperature: 0.7, topP: 0.8, topK: 20),
            synopsis: GenerateParameters(
                maxTokens: 220, temperature: 0.3, topP: 0.8, topK: 20))

        /// `--greedy`, for prompt A/B work: two runs of the same prompt are
        /// byte-identical, so a wording change is the only variable. The seed is
        /// inert at `temperature: 0` (argmax has no RNG) and set only so the
        /// intent is legible.
        static let greedy: SamplingPresets = {
            var presets = recommended
            for keyPath in [
                \SamplingPresets.commentary, \SamplingPresets.followUp,
                \SamplingPresets.answer, \SamplingPresets.synopsis,
            ] {
                presets[keyPath: keyPath].temperature = 0
                presets[keyPath: keyPath].seed = 0
            }
            return presets
        }()
    }
}
