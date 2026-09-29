import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mobile/features/savings/bloc/sep24_bloc.dart';
import 'package:mobile/features/savings/bloc/sep24_event.dart';
import 'package:mobile/features/savings/bloc/sep24_state.dart';
import 'package:mobile/features/savings/models/sep24_models.dart';
import 'package:mobile/features/savings/presentation/sep24_webview_page.dart';

typedef WebViewFactory = Widget Function(BuildContext context, Sep24WebViewRequest request);

class Sep24DepositPage extends StatefulWidget {
  final Sep24Bloc bloc;
  final String? prefillEmail;
  final WebViewFactory? webViewFactory;

  const Sep24DepositPage({
    Key? key,
    required this.bloc,
    this.prefillEmail,
    this.webViewFactory,
  }) : super(key: key);

  @override
  State<Sep24DepositPage> createState() => _Sep24DepositPageState();
}

class _Sep24DepositPageState extends State<Sep24DepositPage> {
  final _amountController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    
    final amountText = _amountController.text;
    final amount = double.tryParse(amountText) ?? 0.0;
    if (amount < 1.0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The minimum deposit is 1.00 USDC.')),
      );
      return;
    }

    widget.bloc.add(StartSep24Deposit(
      Sep24DepositRequest(
        amount: amountText,
        asset: 'USDC',
        email: widget.prefillEmail,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: widget.bloc,
      child: Scaffold(
        appBar: AppBar(title: const Text('Deposit')),
        body: BlocConsumer<Sep24Bloc, Sep24State>(
          listener: (context, state) {
            if (state is Sep24WebViewOpen) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (ctx) => Sep24WebViewPage(
                    bloc: widget.bloc,
                    webViewFactory: widget.webViewFactory ?? defaultSep24WebViewFactory,
                  ),
                ),
              ).then((_) {
                if (widget.bloc.state is! Sep24Success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Deposit cancelled.')),
                  );
                }
              });
            }
          },
          builder: (context, state) {
            final isLoading = state is Sep24Loading;
            
            return Padding(
              padding: const EdgeInsets.all(16.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.prefillEmail != null)
                      Text(widget.prefillEmail!),
                    const Text('USDC (Stellar)'),
                    TextFormField(
                      controller: _amountController,
                      decoration: const InputDecoration(labelText: 'Amount'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      enabled: !isLoading,
                      validator: (value) {
                        final val = double.tryParse(value ?? '');
                        if (val == null || val < 1.0) {
                          return 'The minimum deposit is 1.00 USDC.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    if (state is Sep24Error)
                      Text(
                        state.message,
                        style: const TextStyle(color: Colors.red),
                      ),
                    const SizedBox(height: 16),
                    if (isLoading)
                      const Center(child: CircularProgressIndicator())
                    else
                      ElevatedButton(
                        onPressed: _submit,
                        child: const Text('Continue with deposit'),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
