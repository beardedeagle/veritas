defmodule Veritas.Web.WorkflowLive.Components do
  use Veritas.Web, :html

  attr :field, :map, required: true
  attr :value, :any, default: nil
  attr :prefix, :string, default: "answers"

  def answer_field(assigns) do
    assigns = assign(assigns, :input_name, "#{assigns.prefix}[#{assigns.field["key"]}]")

    ~H"""
    <label class="block text-sm">
      <span class="mb-1.5 block font-medium">{@field["label"]}<span
        :if={@field["required"]}
        class="ml-1 text-error"
      >*</span></span>
      <textarea
        :if={@field["type"] == "textarea"}
        name={@input_name}
        required={@field["required"]}
        rows="4"
        class="textarea textarea-bordered w-full"
      >{@value}</textarea>
      <select
        :if={@field["type"] == "select"}
        name={@input_name}
        required={@field["required"]}
        class="select select-bordered w-full"
      >
        <option value="">Choose…</option><option
          :for={option <- @field["options"] || []}
          value={option}
          selected={option == @value}
        >
          {option}
        </option>
      </select>
      <input
        :if={@field["type"] == "checkbox"}
        type="checkbox"
        name={@input_name}
        value="true"
        checked={@value in [true, "true"]}
        required={@field["required"]}
        class="checkbox checkbox-sm"
      />
      <input
        :if={@field["type"] in ["text", "number"]}
        type={@field["type"]}
        step={if @field["type"] == "number", do: "any", else: nil}
        name={@input_name}
        value={@value}
        required={@field["required"]}
        class="input input-bordered w-full"
      />
    </label>
    """
  end

  attr :steps, :list, required: true
  attr :current, :string, default: ""
  attr :completed, :list, default: []

  def progress(assigns) do
    ~H"""
    <ol class="space-y-2" aria-label="Workflow steps">
      <li
        :for={{step, index} <- Enum.with_index(@steps)}
        class={[
          "rounded-xl border px-4 py-3",
          if(step["id"] == @current, do: "border-primary bg-primary/5", else: "border-base-300")
        ]}
      >
        <div class="flex items-center gap-3">
          <span class={[
            "flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
            if(step["id"] in @completed, do: "bg-success/15 text-success", else: "bg-base-200")
          ]}>{if step["id"] in @completed, do: "✓", else: index + 1}</span><div>
            <p class="text-sm font-semibold">{step["name"]}</p><p class="text-[11px] uppercase tracking-wide text-base-content/50">
              {String.replace(step["phase"], "_", " ")} · {step["kind"]}
            </p>
          </div>
        </div>
      </li>
    </ol>
    """
  end
end
