import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

final class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(startupControllerProvider);
    return switch (state) {
      StartupWelcome() => const _WelcomeView(),
      StartupOnboarding() => _ProfileDraftView(
        key: ValueKey<String>(state.checkpoint.pendingProfileId),
        initialDisplayName: state.checkpoint.draftDisplayName,
      ),
      _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }
}

final class _WelcomeView extends ConsumerWidget {
  const _WelcomeView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            const SizedBox(height: 40),
            Icon(
              Icons.explore_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'The mission ended.\nThe next transfer begins.',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Text(
              'Start privately on this device. Internet access and an online '
              'account are not required.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            const _AccountExplanationCard(),
            const SizedBox(height: 24),
            Semantics(
              button: true,
              label: 'Continue offline with a private Local Profile',
              child: ElevatedButton.icon(
                onPressed: () {
                  unawaited(
                    ref
                        .read(startupControllerProvider.notifier)
                        .continueLocalOnly(),
                  );
                },
                icon: const Icon(Icons.phone_android),
                label: const Text('Continue offline'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'You can choose account setup later from More > Account and Sync.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

final class _ProfileDraftView extends ConsumerStatefulWidget {
  const _ProfileDraftView({required this.initialDisplayName, super.key});

  final String? initialDisplayName;

  @override
  ConsumerState<_ProfileDraftView> createState() => _ProfileDraftViewState();
}

final class _ProfileDraftViewState extends ConsumerState<_ProfileDraftView> {
  late final TextEditingController _controller;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialDisplayName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your Local Profile')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            Text(
              'One private profile on this device',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            const Text(
              'Next Transfer generates a private local profile name. A display '
              'name is optional and can be changed later.',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              enabled: !_finishing,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Display name (optional)',
                hintText: 'Leave blank to use the generated local name',
              ),
              onChanged: (value) {
                unawaited(
                  ref.read(startupControllerProvider.notifier).saveDraft(value),
                );
              },
            ),
            const SizedBox(height: 20),
            const _AccountExplanationCard(),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _finishing
                  ? null
                  : () async {
                      setState(() => _finishing = true);
                      final controller = ref.read(
                        startupControllerProvider.notifier,
                      );
                      final saved = await controller.saveDraft(_controller.text);
                      if (!saved) {
                        if (mounted) setState(() => _finishing = false);
                        return;
                      }
                      await controller.completeOnboarding();
                      if (mounted) {
                        setState(() => _finishing = false);
                      }
                    },
              child: Text(
                _finishing ? 'Creating local profile…' : 'Create local profile',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'No Android permission will be requested during onboarding.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

final class _AccountExplanationCard extends StatelessWidget {
  const _AccountExplanationCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Local use and optional accounts',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              'Local-only: your planner opens and works offline on this device.\n\n'
              'Optional account: a later approved slice can synchronize eligible '
              'records. Account or remote-service problems never remove valid '
              'local access.',
            ),
          ],
        ),
      ),
    );
  }
}
