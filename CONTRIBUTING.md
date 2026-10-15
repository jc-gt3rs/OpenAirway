# Contributing to OpenAirway

Thanks for helping make Airway better. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an [issue](https://github.com/jc-gt3rs/OpenAirway/issues/new) and include:

- Your Mac model and model identifier (run `sysctl hw.model` in Terminal)
- Your macOS version
- Your Airway version (open **About** from the popover) and whether you built it yourself or got it from airway.fan
- What you expected, what happened instead, and the steps to make it happen again

Fan control depends on hardware, so the Mac model matters more than anything else.

## Suggesting an idea

Open an issue that describes the problem you want solved before jumping to a solution. Small, focused ideas are the easiest to ship.

## Sending a pull request

1. Fork the repo and create a branch from `main`.
2. Follow the [build steps](README.md#build-it-yourself) to get Airway running with your own Team ID.
3. Keep the change focused on one thing and match the style of the code around it.
4. Run the tests in Xcode with **⌘U**.
5. **Don't commit your Team ID.** Before you commit, switch it back with `scripts/set-team-id.sh N392C48YLY`, or leave the four files that script touches out of your commit.
6. Open the pull request and explain what changed and why. Screenshots or a short recording help a lot for UI changes.

Changes that touch the privileged helper (`com.airway.helper`) or SMC writes get extra careful review, because they run with admin rights and drive real hardware.

## Licensing of contributions

OpenAirway is licensed under the [GPL-3.0](LICENSE). By sending a pull request, you agree that your contribution is licensed under the GPL-3.0, and that John Cris Antor may also include it in the official Airway builds sold at [airway.fan](https://airway.fan).

## Be kind

Be respectful and assume good intent. Harassment or discrimination of any kind is not welcome here.
