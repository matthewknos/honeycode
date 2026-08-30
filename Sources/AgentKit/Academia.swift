import Foundation

/// What the Academia DLC contributes, in one declaration.
///
/// This is the whole of it that the engine knows about: the skills it installs,
/// and the sentence that says which surfaces it adds. The surfaces themselves
/// are declared where they live — `RootView.SidebarMode` grows a `library` case
/// carrying `dlc: .academia`, and the filter that was already there for
/// `Feature` does the rest. Nothing in the app branches on "is Academia on"; it
/// asks the same question it already asked about Crew and Agents.
///
/// One declaration rather than a protocol and a registry, because there is one
/// DLC. The registry is worth building the day there are two, and building it
/// now would mean making `SidebarMode` and `WorkbenchTab` — both `CaseIterable`
/// and switched on all over the tree — driven by a table, which is a large
/// refactor in service of a hypothetical. What matters for that day is that the
/// seams stay *declarative*, and they do.
enum Academia {

    /// Installed into `Skills.folder` when the switch goes on, and left there
    /// when it goes off.
    ///
    /// Two, and no more. A DLC that arrives with a folder of instructions
    /// nobody asked for is a DLC that spends its first day being deleted. These
    /// are the two things that are true of academic work and false of the
    /// coding the rest of the app assumes: how a paper is structured, and that
    /// a figure has rules a chart in a README does not.
    static var skills: [Skill] {
        [
            Skill(slug: "paper",
                  name: "Academic writing",
                  summary: "How this person's papers are structured, and the "
                         + "conventions to follow when drafting or editing one.",
                  body: paperSkill),
            Skill(slug: "figure",
                  name: "Figures for publication",
                  summary: "What a figure needs before it can go in a paper — "
                         + "units, error bars, panel labels, a print-safe palette.",
                  body: figureSkill),
        ]
    }

    /// Deliberately about *conventions*, not about content.
    ///
    /// A skill that tried to tell an agent how to do research would be wrong on
    /// the first day and unfalsifiable after that. What a skill can carry is the
    /// house style: the things that are the same in every paper this person
    /// writes and that an agent has no way to guess.
    private static let paperSkill = """
    Use this whenever you are drafting, editing or reviewing a section of an
    academic paper.

    ## Structure

    - IMRaD unless the venue says otherwise: Introduction, Methods, Results,
      Discussion. Methods is written so somebody else could repeat the work; if
      a detail is not enough to repeat it, it belongs in the appendix.
    - One claim per paragraph, stated in its first sentence. The rest of the
      paragraph is the evidence for it.
    - The abstract is written last and says what was done, what was found, and
      what it means — in that order, one or two sentences each.

    ## Voice

    - Past tense for what was done, present for what is true.
    - First person plural where the alternative is a passive that hides who did
      something. "We measured" beats "measurements were taken".
    - No hedging stacks. "may possibly suggest" is one hedge too many; pick the
      one you mean.

    ## Numbers

    - Every number carries its unit and its uncertainty. A figure without an
      error bar is a claim without evidence.
    - Significant figures follow the measurement, not the calculator.

    ## Citations

    - Cite the paper that did the work, not the review that mentions it.
    - Never invent a citation. If a claim needs a source and you do not have one,
      write `[CITATION NEEDED: <what it would have to show>]` and move on. A
      plausible-looking reference to a paper that does not exist is the single
      worst thing you can put in a draft.

    ## The document

    Papers here are Word documents, because that is what journals and co-authors
    take. Edit the `.docx` in place rather than producing a Markdown version
    alongside it — a second copy is a second thing to keep in sync, and the one
    that gets sent is always the one you did not update.
    """

    /// The half that pays for itself: the conventions written down, so an
    /// agent drawing a figure for a paper is held to what a journal expects
    /// rather than to what looks good in a README.
    private static let figureSkill = """
    Use this for any figure that is going into a paper, as opposed to a chart
    that is going into a README.

    ## Before drawing anything

    Say what the figure is for in one sentence. A figure that needs a paragraph
    of caption to be readable is a table.

    ## Rules

    - **Axes are labelled, with units, always.** An unlabelled axis is the most
      common defect in a submitted figure.
    - **Error bars, and say what they are.** Standard deviation, standard error
      and a 95% interval look identical and mean different things; the caption
      says which.
    - **Panel labels** are lowercase letters in the top left: (a), (b), (c).
    - **Print-safe colour.** The figure has to survive greyscale and the two
      common colour-vision deficiencies, so colour is never the only thing
      distinguishing two series — pair it with a marker or a dash pattern.
    - **One typeface**, sized so it is still legible at the width the figure will
      actually be printed at, which for a two-column paper is about 85mm.
    - **No chartjunk.** No 3D, no gradients, no drop shadows, no gridlines that
      are darker than the data.

    ## In this app

    Produce the figure as a script — matplotlib or ggplot — written into the
    project, so it can be re-run when the data changes. Nothing here renders a
    chart for you, and a figure that exists only as an image is one nobody can
    correct.
    """
}
